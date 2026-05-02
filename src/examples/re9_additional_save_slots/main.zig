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

const g = struct {
    var allocator: std.mem.Allocator = undefined;
    var io: std.Io = undefined;
    var interop_cache: interop.ManagedTypeCache = undefined;
    var api: re.Api = undefined;
    var sdk: re.api.VerifiedSdk(re.api.specs.minimal.sdk) = undefined;
    var tdb: re.sdk.Tdb = undefined;

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    var threaded: std.Io.Threaded = undefined;

    fn init(init_api: re.Api) !void {
        api = init_api;
        sdk = try api.verifiedSdk(re.api.specs.minimal.sdk);
        tdb = re.sdk.getTdb(.fo(g.sdk)) orelse return error.TdbNotFound;
    }

    fn attach() void {
        threaded = .init(debug_allocator.allocator(), .{});
        allocator = debug_allocator.allocator();
        io = threaded.io();
        interop_cache = .init(debug_allocator.allocator(), io);
    }

    fn reset() void {
        interop_cache.deinit();

        threaded.deinit();
        _ = debug_allocator.detectLeaks();
        _ = debug_allocator.deinit();
    }
};

pub fn pluginLog(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const log_msg = std.fmt.allocPrintSentinel(
        g.allocator,
        (if (scope != .default) ("(" ++ @tagName(scope) ++ "): ") else "") ++ format,
        args,
        0,
    ) catch return;
    defer g.allocator.free(log_msg);
    switch (message_level) {
        .err => g.api.logError("%s", .{log_msg.ptr}),
        .warn => g.api.logWarn("%s", .{log_msg.ptr}),
        else => g.api.logInfo("%s", .{log_msg.ptr}),
    }
}

pub const std_options: std.Options = .{
    .logFn = pluginLog,
};

const log = std.log.scoped(.AdditionalSaves);

fn tdbGetMethod(tdb: re.sdk.Tdb, comptime type_name: [:0]const u8, comptime method_sig: [:0]const u8) !?re.sdk.Method {
    const type_def = tdb.findType(.fo(g.sdk), type_name) orelse return null;
    const metadata = try g.interop_cache.getOrCacheMethodMetadata(.fo(g.sdk), type_def, method_sig);
    return metadata.handle;
}

var pending_unit: ?GuiSaveLoadControllerUnit = null;
var auto_save_slots: i32 = 0;

fn init(api: re.Api) !void {
    try g.init(api);

    log.info(
        "RE9 Save Slot increase in Zig! Required REFramework Version: {}.{}.{}",
        .{
            re.PluginVersion.default.major,
            re.PluginVersion.default.minor,
            re.PluginVersion.default.patch,
        },
    );

    const m1 = (try tdbGetMethod(g.tdb, "app.GuiSaveLoadController.Unit", "onSetup")) orelse {
        log.err("Failed to find method app.GuiSaveLoadController.Unit.onSetup", .{});
        return;
    };
    _ = m1.addHook(
        .fo(g.sdk.safe().functions),
        struct {
            fn func(args_opt: ?[]?*anyopaque, _: ?[]re.sdk.TypeDefinition, _: u64) re.api.HookCall {
                const args = args_opt orelse return .call_original;
                if (args.len < 2) return .call_original;
                {
                    @setRuntimeSafety(false);
                    const arg = args[1] orelse return .call_original;
                    const mo: re.sdk.ManagedObject = .{ .raw = @ptrCast(@alignCast(arg)) };
                    pending_unit = GuiSaveLoadControllerUnit.init(&g.interop_cache, .fo(g.sdk), mo) catch return .call_original;
                }
                return .call_original;
            }
        }.func,
        struct {
            fn func(_: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                if (!initialized) return;

                var new_scope = g.interop_cache.newScope(g.allocator);
                defer new_scope.deinit();

                const unit = pending_unit orelse return;

                defer pending_unit = null;

                const res = blk: {
                    const current = unit.get(._SaveItemNum, &new_scope, .fo(g.sdk)) catch |e| break :blk e;
                    const max_save_games_with_auto = max_save_games + auto_save_slots;
                    if (current < max_save_games_with_auto) {
                        unit.set(._SaveItemNum, &new_scope, .fo(g.sdk), max_save_games_with_auto) catch |e| break :blk e;
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

    const m2 = (try tdbGetMethod(g.tdb, "app.GuiSaveLoadModel", "makeSaveDataList")) orelse {
        log.err("Failed to find method app.GuiSaveLoadModel.makeSaveDataList", .{});
        return;
    };
    _ = m2.addHook(
        .fo(g.sdk.safe().functions),
        null,
        struct {
            fn func(retval_opt: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                @setRuntimeSafety(false);

                if (!initialized) return;
                const retval_ptr = retval_opt orelse return;

                var scope = g.interop_cache.newScope(g.allocator);
                defer scope.deinit();

                const GuiSaveDataInfoT = GuiSaveDataInfo.Runtime.get(&g.interop_cache, .fo(g.sdk)) catch return;
                const GuiSaveLoadModelT = GuiSaveLoadModel.Runtime.get(&g.interop_cache, .fo(g.sdk)) catch return;

                const arr = SystemArray.init(
                    &g.interop_cache,
                    .fo(g.sdk),
                    .{ .raw = @ptrCast(@alignCast(retval_ptr.*)) },
                ) catch return;
                var len = arr.call(.GetLength, &scope, .fo(g.sdk), .{0}) catch return;

                const max_save_games_with_auto: usize = @intCast(max_save_games + auto_save_slots);

                if (len >= max_save_games_with_auto) return;

                const new_arr_mo = re.sdk.createManagedArray(
                    .fo(g.sdk),
                    GuiSaveDataInfoT.metadata.type_def,
                    @truncate(max_save_games_with_auto),
                ) orelse {
                    log.err("Failed to create expanded array", .{});
                    return;
                };
                const new_arr = SystemArray.init(&g.interop_cache, .fo(g.sdk), new_arr_mo) catch {
                    log.err("Failed to init SystemArray wrapper for new array", .{});
                    return;
                };
                new_arr_mo.addRef(.fo(g.sdk));

                if (len == 0) {
                    // An attempt to restore auto save slots...? Might crash for no save complete new-game state.
                    for (0..@intCast(auto_save_slots)) |i| {
                        const new_save_info = (GuiSaveLoadModelT.callStatic(
                            .makeSaveData,
                            &scope,
                            .fo(g.sdk),
                            .{ SaveSlotCategory.auto, i },
                        ) catch continue) orelse continue;
                        new_arr.call(.SetValue, &scope, .fo(g.sdk), .{ new_save_info, i }) catch continue;
                        new_save_info.managed.addRef(.fo(g.sdk));
                    }
                    len += auto_save_slots;
                } else {
                    for (0..@intCast(len)) |i| {
                        const item = (arr.call(.GetValue, &scope, .fo(g.sdk), .{i}) catch continue) orelse continue;
                        new_arr.call(.SetValue, &scope, .fo(g.sdk), .{ item, i }) catch continue;
                    }
                }

                for (@intCast(len)..max_save_games_with_auto) |i| {
                    const new_save_info = (GuiSaveLoadModelT.callStatic(
                        .makeSaveData,
                        &scope,
                        .fo(g.sdk),
                        .{ SaveSlotCategory.game, i },
                    ) catch continue) orelse continue;
                    new_arr.call(.SetValue, &scope, .fo(g.sdk), .{ new_save_info, i }) catch continue;
                    new_save_info.managed.addRef(.fo(g.sdk));
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
        .fo(g.sdk),
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
        .fo(g.sdk),
        .{SaveSlotSegmentType.default_0},
    );
    if (value_coll) |v| {
        // ValueType is handled by cache value arena.
        if (v.get(
            "_Source",
            ?re.api.sdk.ManagedObject,
            scope,
            .fo(g.sdk),
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
        .fo(g.sdk),
    )) orelse {
        log.err("Could not access _Dict", .{});
        return null;
    };

    return try scope.callMethod(
        dict,
        "FindValue(app.SaveSlotSegmentType)",
        ?re.api.sdk.ManagedObject,
        .fo(g.sdk),
        .{SaveSlotSegmentType.default_0},
    );
}

fn expandGamePartition(save_mgr: re.api.sdk.ManagedObject) !bool {
    var scope = g.interop_cache.newScope(g.allocator);
    defer scope.deinit();

    const SaveMgrT = try g.interop_cache.resolve("app.SaveServiceManager", g.tdb, .fo(g.sdk));

    const item_set = (try getDefaultSegmentItemSet(&scope, save_mgr)) orelse return false;
    const partitions_arr = (try scope.callMethod(
        item_set,
        "toValueArray()",
        ?SystemArray,
        .fo(g.sdk),
        .{}, // args
    ) orelse {
        log.err("Could not get partitions array", .{});
        return false;
    });
    const partitions_len: usize = @intCast(try partitions_arr.call(.GetLength, &scope, .fo(g.sdk), .{0}));
    log.info("Found {} partitions in Default_0 segment", .{partitions_len});

    var game_partition: ?SaveSlotPartition = null;
    var game_partition_slots: i32 = 0;

    for (0..partitions_len) |i| {
        const mo = (try partitions_arr.call(.GetValue, &scope, .fo(g.sdk), .{i})) orelse continue;
        const partition = SaveSlotPartition.init(&g.interop_cache, .fo(g.sdk), mo) catch continue;

        const usage = partition.get(._Usage, &scope, .fo(g.sdk)) catch continue;
        const slot_count = partition.get(._SlotCount, &scope, .fo(g.sdk)) catch continue;
        log.info("  Partition {}: Usage={}, HeadSlotId={}, SlotCount={}", .{
            i,
            usage,
            partition.get(._HeadSlotId, &scope, .fo(g.sdk)) catch continue,
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

    try game_partition.?.set(._SlotCount, &scope, .fo(g.sdk), max_save_games);
    log.info("Patched Game partition _SlotCount: {} -> {}", .{ game_partition_slots, max_save_games });

    const old_max = try SaveMgrT.scoped(&scope).get(save_mgr, ._MaxUseSaveSlotCount, i32, .fo(g.sdk));
    const new_max = old_max + extra_slots;
    try SaveMgrT.scoped(&scope).set(save_mgr, ._MaxUseSaveSlotCount, .fo(g.sdk), new_max);
    log.info("Patched _MaxUseSaveSlotCount: {} -> {}", .{ old_max, new_max });

    SaveMgrT.scoped(&scope).call(
        save_mgr,
        "reloadSaveSlotInfo()",
        void,
        .fo(g.sdk),
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

    g.api.lockLua();
    defer g.api.unlockLua();

    const save_mgr = re.api.sdk.getManagedSingleton(.fo(g.sdk), "app.SaveServiceManager") orelse return;
    initialized = try expandGamePartition(save_mgr);
}

fn onUpdate() void {
    newFrame() catch |e| {
        if (g.interop_cache.ownDiagnostics()) |val| {
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
        .onDeviceReset = struct {
            fn func() void {
                g.reset();
            }
        }.func,
    });
}

const DLL_PROCESS_DETACH: windows.DWORD = 0;
const DLL_PROCESS_ATTACH: windows.DWORD = 1;

pub export fn DllMain(
    hinstDLL: windows.HINSTANCE,
    fdwReason: windows.DWORD,
    lpReserved: windows.LPVOID,
) callconv(.winapi) windows.BOOL {
    _ = hinstDLL;
    _ = lpReserved;

    switch (fdwReason) {
        DLL_PROCESS_ATTACH => {
            g.attach();
        },
        DLL_PROCESS_DETACH => {
            g.reset();
        },
        else => {},
    }

    return .TRUE;
}
