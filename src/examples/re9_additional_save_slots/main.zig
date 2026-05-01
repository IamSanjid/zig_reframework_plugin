/// 1-to-1 Implementation of https://github.com/praydog/RE9AdditionalSaveSlots/blob/87c18cb40ff672e1cc9107e10cd380a10acc07ec/reframework/plugins/source/AdditionalSaves.cs#L1
const std = @import("std");
const re = @import("reframework");

const managed_types = @import("managed_types.zig");

const windows = std.os.windows;

const interop = re.interop;

const SystemArray = managed_types.SystemArray;
const SaveSlotSegmentType = managed_types.SaveSlotSegmentType;
const SaveSlotCategory = managed_types.SaveSlotCategory;
const SaveSlotPartition = managed_types.SaveSlotPartition;
const GuiSaveLoadControllerUnit = managed_types.GuiSaveLoadControllerUnit;
const GuiSaveDataInfo = managed_types.GuiSaveDataInfo;
const GuiSaveLoadModel = managed_types.GuiSaveLoadModel;

const max_save_games = 90;

const State = struct {
    api: re.Api,
    sdk: re.api.VerifiedSdk(re.api.specs.minimal.sdk),
    tdb: re.sdk.Tdb,
    allocator: std.mem.Allocator,
    io: std.Io,
    interop_cache: interop.ManagedTypeCache,
};

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
var threaded: std.Io.Threaded = undefined;
var g_state: State = undefined;

pub fn pluginLog(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const log_msg = std.fmt.allocPrintSentinel(
        g_state.allocator,
        (if (scope != .default) ("(" ++ @tagName(scope) ++ "): ") else "") ++ format,
        args,
        0,
    ) catch return;
    defer g_state.allocator.free(log_msg);
    switch (message_level) {
        .err => g_state.api.logError("%s", .{log_msg.ptr}),
        .warn => g_state.api.logWarn("%s", .{log_msg.ptr}),
        else => g_state.api.logInfo("%s", .{log_msg.ptr}),
    }
}

pub const std_options: std.Options = .{
    .logFn = pluginLog,
};

const log = std.log.scoped(.AdditionalSaves);

fn tdbGetMethod(tdb: re.sdk.Tdb, comptime type_name: [:0]const u8, comptime method_sig: [:0]const u8) !?re.sdk.Method {
    const type_def = tdb.findType(.fo(g_state.sdk), type_name) orelse return null;
    const metadata = try g_state.interop_cache.getOrCacheMethodMetadata(.fo(g_state.sdk), type_def, method_sig);
    return metadata.handle;
}

var pending_unit: ?GuiSaveLoadControllerUnit = null;
var auto_save_slots: i32 = 0;

fn init(api: re.Api) !void {
    g_state.api = api;
    g_state.sdk = try g_state.api.verifiedSdk(re.api.specs.minimal.sdk);

    log.info(
        "RE9 Save Slot increase in Zig! Required REFramework Version: {}.{}.{}",
        .{
            re.PluginVersion.default.major,
            re.PluginVersion.default.minor,
            re.PluginVersion.default.patch,
        },
    );

    const tdb = re.sdk.getTdb(.fo(g_state.sdk)) orelse {
        log.err("Failed to get TDB", .{});
        return;
    };
    g_state.tdb = tdb;

    const m1 = (try tdbGetMethod(tdb, "app.GuiSaveLoadController.Unit", "onSetup")) orelse {
        log.err("Failed to find method app.GuiSaveLoadController.Unit.onSetup", .{});
        return;
    };
    _ = m1.addHook(
        .fo(g_state.sdk.safe().functions),
        struct {
            fn func(args_opt: ?[]?*anyopaque, _: ?[]re.sdk.TypeDefinition, _: u64) re.api.HookCall {
                const args = args_opt orelse return .call_original;
                if (args.len < 2) return .call_original;
                {
                    @setRuntimeSafety(false);
                    const arg = args[1] orelse return .call_original;
                    const mo: re.sdk.ManagedObject = .{ .raw = @ptrCast(@alignCast(arg)) };
                    pending_unit = GuiSaveLoadControllerUnit.init(&g_state.interop_cache, .fo(g_state.sdk), mo) catch return .call_original;
                }
                return .call_original;
            }
        }.func,
        struct {
            fn func(_: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                if (!initialized) return;

                var new_scope = g_state.interop_cache.newScope(g_state.allocator);
                defer new_scope.deinit();

                const unit = pending_unit orelse return;

                defer pending_unit = null;

                const res = blk: {
                    const current = unit.get(._SaveItemNum, &new_scope, .fo(g_state.sdk)) catch |e| break :blk e;
                    const max_save_games_with_auto = max_save_games + auto_save_slots;
                    if (current < max_save_games_with_auto) {
                        unit.set(._SaveItemNum, &new_scope, .fo(g_state.sdk), max_save_games_with_auto) catch |e| break :blk e;
                        log.info("Patched GUI _SaveItemNum: {} -> {}", .{ current, max_save_games_with_auto });
                    }
                    break :blk {};
                };

                res catch |e| {
                    log.err("onSetup patch failed: {}", .{e});
                };
            }
        }.func,
        false,
    );

    const m2 = (try tdbGetMethod(tdb, "app.GuiSaveLoadModel", "makeSaveDataList")) orelse {
        log.err("Failed to find method app.GuiSaveLoadModel.makeSaveDataList", .{});
        return;
    };
    _ = m2.addHook(
        .fo(g_state.sdk.safe().functions),
        null,
        struct {
            fn func(retval_opt: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                @setRuntimeSafety(false);

                if (!initialized) return;
                const retval_ptr = retval_opt orelse return;

                var scope = g_state.interop_cache.newScope(g_state.allocator);
                defer scope.deinit();

                const GuiSaveDataInfoT = GuiSaveDataInfo.Runtime.get(&g_state.interop_cache, .fo(g_state.sdk)) catch return;
                const GuiSaveLoadModelT = GuiSaveLoadModel.Runtime.get(&g_state.interop_cache, .fo(g_state.sdk)) catch return;

                const arr = SystemArray.init(
                    &g_state.interop_cache,
                    .fo(g_state.sdk),
                    .{ .raw = @ptrCast(@alignCast(retval_ptr.*)) },
                ) catch return;
                var len = arr.call(.GetLength, &scope, .fo(g_state.sdk), .{0}) catch return;

                const max_save_games_with_auto: usize = @intCast(max_save_games + auto_save_slots);

                if (len >= max_save_games_with_auto) return;

                const new_arr_mo = re.sdk.createManagedArray(
                    .fo(g_state.sdk),
                    GuiSaveDataInfoT.metadata.type_def,
                    @truncate(max_save_games_with_auto),
                ) orelse {
                    log.err("Failed to create expanded array", .{});
                    return;
                };
                const new_arr = SystemArray.init(&g_state.interop_cache, .fo(g_state.sdk), new_arr_mo) catch {
                    log.err("Failed to init SystemArray wrapper for new array", .{});
                    return;
                };
                new_arr_mo.addRef(.fo(g_state.sdk));

                if (len == 0) {
                    // An attempt to restore auto save slots...? Might crash for no save complete new-game state.
                    for (0..@intCast(auto_save_slots)) |i| {
                        const new_save_info = (GuiSaveLoadModelT.callStatic(
                            .makeSaveData,
                            &scope,
                            .fo(g_state.sdk),
                            .{ SaveSlotCategory.auto, i },
                        ) catch continue) orelse continue;
                        new_arr.call(.SetValue, &scope, .fo(g_state.sdk), .{ new_save_info, i }) catch continue;
                        new_save_info.managed.addRef(.fo(g_state.sdk));
                    }
                    len += auto_save_slots;
                } else {
                    for (0..@intCast(len)) |i| {
                        const item = (arr.call(.GetValue, &scope, .fo(g_state.sdk), .{i}) catch continue) orelse continue;
                        new_arr.call(.SetValue, &scope, .fo(g_state.sdk), .{ item, i }) catch continue;
                    }
                }

                for (@intCast(len)..max_save_games_with_auto) |i| {
                    const new_save_info = (GuiSaveLoadModelT.callStatic(
                        .makeSaveData,
                        &scope,
                        .fo(g_state.sdk),
                        .{ SaveSlotCategory.game, i },
                    ) catch continue) orelse continue;
                    new_arr.call(.SetValue, &scope, .fo(g_state.sdk), .{ new_save_info, i }) catch continue;
                    new_save_info.managed.addRef(.fo(g_state.sdk));
                }

                log.info("Expanded makeSaveDataList: {} -> {}", .{ len, max_save_games_with_auto });
                retval_ptr.* = @ptrCast(@alignCast(new_arr_mo.raw));
            }
        }.func,
        false,
    );
}

fn getDefaultSegmentItemSet(scope: *interop.Scope, save_mgr: re.api.sdk.ManagedObject) !?re.api.sdk.ManagedObject {
    const partitions_dict = (try scope.getField(
        save_mgr,
        "_SaveSlotPartitions",
        ?re.api.sdk.ManagedObject,
        .fo(g_state.sdk),
    )) orelse {
        log.err("Could not access _SaveSlotPartitions", .{});
        return null;
    };

    const value_coll = try scope.callMethod(
        partitions_dict,
        "getValue(app.SaveSlotSegmentType)",
        // Special type for VmObjType.valtype more info:
        // https://github.com/praydog/REFramework/blob/ea66d322fbe2ebb7e2efd8fd6aa6b06779da6f76/src/mods/bindings/Sdk.cpp#L365
        ?interop.ValueType,
        .fo(g_state.sdk),
        .{SaveSlotSegmentType.default_0},
    );
    if (value_coll) |v| {
        // ValueType is handled by cache value arena.
        if (v.get(
            "_Source",
            ?re.api.sdk.ManagedObject,
            scope,
            .fo(g_state.sdk),
        )) |item_set| {
            if (item_set) |s| {
                return s;
            }
        } else |_| {}

        log.warn("Could not read _Source from ValueCollection", .{});
    }

    log.info("getValue(Default_0) failed, trying _Dict fallback", .{});
    const dict = (try scope.getField(
        partitions_dict,
        "_Dict",
        ?re.api.sdk.ManagedObject,
        .fo(g_state.sdk),
    )) orelse {
        log.err("Could not access _Dict", .{});
        return null;
    };

    return try scope.callMethod(
        dict,
        "FindValue(app.SaveSlotSegmentType)",
        ?re.api.sdk.ManagedObject,
        .fo(g_state.sdk),
        .{SaveSlotSegmentType.default_0},
    );
}

fn expandGamePartition(save_mgr: re.api.sdk.ManagedObject) !bool {
    var scope = g_state.interop_cache.newScope(g_state.allocator);
    defer scope.deinit();

    const SaveMgrT = try g_state.interop_cache.resolve("app.SaveServiceManager", g_state.tdb, .fo(g_state.sdk));

    const item_set = (try getDefaultSegmentItemSet(&scope, save_mgr)) orelse return false;
    const partitions_arr = (try scope.callMethod(
        item_set,
        "toValueArray()",
        ?SystemArray,
        .fo(g_state.sdk),
        .{}, // args
    ) orelse {
        log.err("Could not get partitions array", .{});
        return false;
    });
    const partitions_len: usize = @intCast(try partitions_arr.call(.GetLength, &scope, .fo(g_state.sdk), .{0}));
    log.info("Found {} partitions in Default_0 segment", .{partitions_len});

    var game_partition: ?SaveSlotPartition = null;
    var game_partition_slots: i32 = 0;

    for (0..partitions_len) |i| {
        const mo = (try partitions_arr.call(.GetValue, &scope, .fo(g_state.sdk), .{i})) orelse continue;
        const partition = SaveSlotPartition.init(&g_state.interop_cache, .fo(g_state.sdk), mo) catch continue;

        const usage = partition.get(._Usage, &scope, .fo(g_state.sdk)) catch continue;
        const slot_count = partition.get(._SlotCount, &scope, .fo(g_state.sdk)) catch continue;
        log.info("  Partition {}: Usage={}, HeadSlotId={}, SlotCount={}", .{
            i,
            usage,
            partition.get(._HeadSlotId, &scope, .fo(g_state.sdk)) catch continue,
            slot_count,
        });

        if (usage == .game) {
            game_partition = partition;
            game_partition_slots = slot_count;
        } else if (usage == .auto) {
            auto_save_slots = slot_count;
        }
    }

    if (game_partition == null) {
        log.err("Could not find Game partition (category=Game)", .{});
        return false;
    }

    if (game_partition_slots >= max_save_games) {
        log.info("Game partition already has {} slots, nothing to do", .{game_partition_slots});
        return true;
    }

    const extra_slots = max_save_games - game_partition_slots;

    try game_partition.?.set(._SlotCount, &scope, .fo(g_state.sdk), max_save_games);
    log.info("Patched Game partition _SlotCount: {} -> {}", .{ game_partition_slots, max_save_games });

    const old_max = try SaveMgrT.scoped(&scope).get(save_mgr, ._MaxUseSaveSlotCount, i32, .fo(g_state.sdk));
    const new_max = old_max + extra_slots;
    try SaveMgrT.scoped(&scope).set(save_mgr, ._MaxUseSaveSlotCount, .fo(g_state.sdk), new_max);
    log.info("Patched _MaxUseSaveSlotCount: {} -> {}", .{ old_max, new_max });

    SaveMgrT.scoped(&scope).call(
        save_mgr,
        "reloadSaveSlotInfo()",
        void,
        .fo(g_state.sdk),
        .{},
    ) catch |e| {
        log.warn("reloadSaveSlotInfo failed: {}", .{e});
    };

    return true;
}

var initialized = false;

fn newFrame() !void {
    if (initialized) {
        return;
    }

    g_state.api.lockLua();
    defer g_state.api.unlockLua();

    const save_mgr = re.api.sdk.getManagedSingleton(.fo(g_state.sdk), "app.SaveServiceManager") orelse return;
    initialized = try expandGamePartition(save_mgr);
}

fn onUpdate() void {
    newFrame() catch |e| {
        if (g_state.interop_cache.ownDiagnostics()) |val| {
            if (val.len > 0) {
                log.err("Interop error: \n{s}", .{val});
            }
        } else |_| {}
        log.err("Error newFrame: {}", .{e});
    };
}

comptime {
    re.initPlugin(init, .{
        .requiredVersion = .{
            .gameName = "RE9",
        },
        .onPreApplicationEntry = &.{
            .{ "UpdateBehavior", onUpdate },
        },
    });
}

const DLL_PROCESS_DETACH: windows.DWORD = 0;
const DLL_PROCESS_ATTACH: windows.DWORD = 1;

pub fn DllMain(
    hinstDLL: windows.HINSTANCE,
    fdwReason: windows.DWORD,
    lpReserved: windows.LPVOID,
) callconv(.winapi) windows.BOOL {
    _ = hinstDLL;
    _ = lpReserved;

    switch (fdwReason) {
        DLL_PROCESS_ATTACH => {
            g_state.allocator = debug_allocator.allocator();
            threaded = .init(g_state.allocator, .{});
            g_state.io = threaded.io();
            g_state.interop_cache = .init(g_state.allocator, g_state.io);
        },
        DLL_PROCESS_DETACH => {
            threaded.deinit();
            _ = debug_allocator.detectLeaks();
            _ = debug_allocator.deinit();
        },
        else => {},
    }

    return .TRUE;
}
