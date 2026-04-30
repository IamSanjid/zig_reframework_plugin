const std = @import("std");

const re = @import("reframework");

const win32 = @import("win32");
const cimgui = @import("cimgui");

const managed_types = @import("managed_types.zig");
const ui = @import("ui.zig");

const windows = std.os.windows;

const interop = re.interop;

const SystemArray = managed_types.SystemArray;
const ItemDetails = managed_types.ItemDetails;
const ItemDetailData = managed_types.ItemDetailData;
const ItemCategory = managed_types.ItemCategory;
const ItemId = managed_types.ItemId;

const ItemManager = re.sdk.ManagedObject;

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

const log = std.log.scoped(.re9_forced_items);

const verified_sdk_spec = re.api.specs.extend(
    re.api.specs.minimal.sdk,
    .{ .field = .{ .extend = .{.get_name} } },
);

pub const g = struct {
    pub var allocator: std.mem.Allocator = undefined;
    pub var io: std.Io = undefined;
    pub var interop_cache: re.interop.ManagedTypeCache = undefined;
    pub var api: re.api.Api = undefined;
    pub var sdk: re.api.VerifiedSdk(verified_sdk_spec) = undefined;
    pub var tdb: re.sdk.Tdb = undefined;

    pub var items: Items = undefined;

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    var threaded: std.Io.Threaded = undefined;

    pub var value_arena: std.heap.ArenaAllocator = .init(debug_allocator.allocator());
    pub var cache_arena: std.heap.ArenaAllocator = .init(debug_allocator.allocator());

    fn init(init_api: re.Api) !void {
        api = init_api;
        g.sdk = try api.verifiedSdk(verified_sdk_spec);
        g.tdb = re.sdk.getTdb(.fo(g.sdk)) orelse return error.TdbNotFound;

        items = .init(re.sdk.getManagedSingleton(.fo(g.sdk), "app.ItemManager") orelse return error.ItemManagerNotFound);
    }

    fn attach() void {
        threaded = .init(debug_allocator.allocator(), .{});
        allocator = debug_allocator.allocator();
        io = threaded.io();
        interop_cache = .init(cache_arena.allocator(), value_arena.allocator(), io);
    }

    fn reset() void {
        interop_cache.deinit();

        _ = value_arena.reset(.free_all);
        _ = cache_arena.reset(.free_all);

        threaded.deinit();
        _ = debug_allocator.detectLeaks();
        _ = debug_allocator.deinit();
    }
};

pub const Items = struct {
    categories: std.AutoHashMap(ItemCategory, [:0]const u8),
    name_cache: std.AutoHashMap(ItemId, [:0]const u8),
    caption_cache: std.AutoHashMap(ItemId, [:0]const u8),
    manager: ItemManager,

    pub const IteratorAll = struct {
        owner: *Items,
        values: SystemArray,
        len: i32,
        next_idx: i32 = 0,

        pub fn next(self: *IteratorAll) !?ItemDetails {
            if (self.next_idx >= self.len) return null;

            while (self.next_idx < self.len) {
                defer self.next_idx += 1;

                const item_detail_mo = (try self.values.call(.GetValue, .fo(g.sdk), .{self.next_idx})) orelse
                    return error.ItemDetailDataNotFound;

                const item_detail = ItemDetailData.init(&g.interop_cache, .fo(g.sdk), item_detail_mo) catch continue;
                const item_category = item_detail.get(._ItemCategory, .fo(g.sdk)) catch continue;

                const id = item_detail.get(._ItemID, .fo(g.sdk)) catch continue;

                const name = blk: {
                    const name_entry = try self.owner.name_cache.getOrPut(id);
                    if (name_entry.found_existing) {
                        break :blk name_entry.value_ptr.*;
                    } else {
                        // arena allocated ValueType, reset on deinit
                        const name_message_id = item_detail.get(._NameMessageId, .fo(g.sdk)) catch continue;

                        const name_message = g.interop_cache.callStaticMethod(
                            "via.gui.message",
                            "get(System.Guid)",
                            .{},
                            .{ .type = interop.SystemStringView },
                            .fo(g.sdk),
                            .{name_message_id},
                        ) catch continue;

                        var name_message_utf8 = try std.unicode.utf16LeToUtf8AllocZ(g.cache_arena.allocator(), name_message.data);

                        if (name_message_utf8.len == 0) {
                            name_message_utf8 = try std.fmt.allocPrintSentinel(g.cache_arena.allocator(), "UnknownName_{}", .{self.next_idx}, 0);
                        }

                        name_entry.value_ptr.* = name_message_utf8;

                        break :blk name_message_utf8;
                    }
                };

                const caption = blk: {
                    const caption_entry = try self.owner.caption_cache.getOrPut(id);
                    if (caption_entry.found_existing) {
                        break :blk caption_entry.value_ptr.*;
                    } else {
                        // arena allocated ValueType, reset on deinit
                        const caption_message_id = item_detail.get(._CaptionMessageId, .fo(g.sdk)) catch continue;

                        const caption_message = g.interop_cache.callStaticMethod(
                            "via.gui.message",
                            "get(System.Guid)",
                            .{},
                            .{ .type = interop.SystemStringView },
                            .fo(g.sdk),
                            .{caption_message_id},
                        ) catch continue;

                        var caption_message_utf8 = try std.unicode.utf16LeToUtf8AllocZ(g.cache_arena.allocator(), caption_message.data);

                        if (caption_message_utf8.len == 0) {
                            caption_message_utf8 = try std.fmt.allocPrintSentinel(g.cache_arena.allocator(), "UnknownCaption_{}", .{self.next_idx}, 0);
                        }

                        caption_entry.value_ptr.* = caption_message_utf8;

                        break :blk caption_message_utf8;
                    }
                };

                const slot_capacity_data = item_detail.get(._SlotCapacityData, .fo(g.sdk)) catch continue;
                return ItemDetails{
                    .id = id,
                    .category = item_category,
                    .name = name,
                    .caption = caption,
                    .base_capacity = slot_capacity_data.get(._BaseCapacity, .fo(g.sdk)) catch continue,
                    .base_item_box_capacity = slot_capacity_data.get(._BaseItemBoxCapacity, .fo(g.sdk)) catch continue,
                };
            }

            return null;
        }

        pub fn deinit(self: IteratorAll) void {
            self.values.managed.release(.fo(g.sdk));
            _ = g.value_arena.reset(.retain_capacity);
        }
    };

    pub const CategoriesIterator = struct {
        iter: std.AutoHashMap(ItemCategory, [:0]const u8).Iterator,

        pub fn next(self: *CategoriesIterator) ?struct {
            category: ItemCategory,
            name: [:0]const u8,
        } {
            const entry = self.iter.next() orelse return null;
            return .{
                .category = entry.key_ptr.*,
                .name = entry.value_ptr.*,
            };
        }
    };

    fn init(manager: ItemManager) Items {
        return Items{
            .categories = .init(g.cache_arena.allocator()),
            .name_cache = .init(g.cache_arena.allocator()),
            .caption_cache = .init(g.cache_arena.allocator()),
            .manager = manager,
        };
    }

    pub fn iteratorAll(self: *Items) !IteratorAll {
        const item_catalog = try g.interop_cache.getField(self.manager, ._ItemCatalog, re.sdk.ManagedObject, .fo(g.sdk));
        // arena allocated ValueType, reset on deinit
        const values_collection = try g.interop_cache.callMethod(
            item_catalog,
            "get_Values",
            .{},
            .{ .type = interop.ValueType },
            .fo(g.sdk),
            .{},
        );
        const values = try values_collection.call(
            "toArray()",
            .{},
            .{ .type = SystemArray },
            &g.interop_cache,
            .fo(g.sdk),
            .{},
        );
        values.managed.addRef(.fo(g.sdk));
        const len = try values.call(.GetLength, .fo(g.sdk), .{0});
        return .{
            .owner = self,
            .len = len,
            .values = values,
        };
    }

    pub fn categoriesIterator(self: *const Items) CategoriesIterator {
        return .{
            .iter = self.categories.iterator(),
        };
    }
};

fn tdbGetMethod(tdb: re.sdk.Tdb, comptime type_name: [:0]const u8, comptime method_sig: [:0]const u8) !?interop.MethodMetadata {
    const type_def = tdb.findType(.fo(g.sdk), type_name) orelse return null;
    const metadata = try g.interop_cache.getOrCacheMethodMetadata(.fo(g.sdk), type_def, method_sig);
    return metadata;
}

fn populateItemCategories() !void {
    g.api.lockLua();
    defer g.api.unlockLua();

    const item_category_typedef = g.tdb.findType(.fo(g.sdk), "app.ItemCategory") orelse return error.ItemCategoryTypeNotFound;
    {
        const fields_len = item_category_typedef.getNumFields(.fo(g.sdk));
        var item_category_fields = try std.ArrayList(re.sdk.Field).initCapacity(g.value_arena.allocator(), fields_len);
        defer item_category_fields.deinit(g.value_arena.allocator());

        const item_category_fields_slice = item_category_fields.addManyAsSliceBounded(fields_len) catch unreachable;
        const fields = try item_category_typedef.getFields(.fo(g.sdk), item_category_fields_slice);

        for (fields) |field| {
            const field_type = field.getType(.fo(g.sdk)) orelse continue;
            if (!field.isStatic(.fo(g.sdk)) or field_type.raw != item_category_typedef.raw) continue;

            const name = field.getName(.fo(g.sdk)) orelse continue;
            const data: *?*anyopaque = @ptrCast(@alignCast(field.getDataRaw(.fo(g.sdk), null, false) orelse continue));
            const field_value = interop.defaultToZigInterop(re.sdk.ManagedObject)(
                @constCast(&g.sdk),
                &g.interop_cache,
                field_type,
                data,
            ) catch continue;

            try g.items.categories.put(field_value, name);
        }
    }

    log.debug("ItemCategories: {}", .{g.items.categories.count()});
}

fn onStart() !void {
    try populateItemCategories();
}

fn onPlayerItemChange() !void {}

fn installHooks() !void {
    const onStartFn = (try tdbGetMethod(g.tdb, "app.LevelPlayerCreateController", "start()")) orelse
        return error.AssociateItemMethodNotFound;
    _ = onStartFn.handle.addHook(
        .fo(g.sdk.safe().functions),
        null,
        struct {
            fn func(_: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                onStart() catch |e| {
                    log.err("Error onStart: {}", .{e});
                };
            }
        }.func,
        false,
    );

    const onItemAcquiredFn = (try tdbGetMethod(g.tdb, "app.GuiManagerBehavior", "onItemAcquired(app.ItemAcquiredInfo)")) orelse
        return error.AssociateItemMethodNotFound;
    _ = onItemAcquiredFn.handle.addHook(
        .fo(g.sdk.safe().functions),
        null,
        struct {
            fn func(_: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                onPlayerItemChange() catch |e| {
                    log.err("Error onPlayerItemChange: {}", .{e});
                };
            }
        }.func,
        false,
    );

    const onItemStockChangedFn = (try tdbGetMethod(g.tdb, "app.GuiManagerBehavior", "onItemStockChanged(app.InventoryStockEventArgs)")) orelse
        return error.AssociateItemMethodNotFound;
    _ = onItemStockChangedFn.handle.addHook(
        .fo(g.sdk.safe().functions),
        null,
        struct {
            fn func(_: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                onPlayerItemChange() catch |e| {
                    log.err("Error onPlayerItemChange: {}", .{e});
                };
            }
        }.func,
        false,
    );

    // app.GuiManagerBehavior
    // onItemAcquired(app.ItemAcquiredInfo)
    // onItemStockChanged(app.InventoryStockEventArgs)

    // app.PlayerContext
    // get_InventoryUserID()
}

fn init(api: re.Api) !void {
    try g.init(api);

    log.info(
        "RE9 Forced Items Hacks in Zig! Required REFramework Version: {}.{}.{}",
        .{
            re.PluginVersion.default.major,
            re.PluginVersion.default.minor,
            re.PluginVersion.default.patch,
        },
    );

    try installHooks();
}

fn onUpdate() void {}

fn onDeviceReset() void {
    log.info("Device reset detected, clearing interop cache", .{});

    g.reset();
}

comptime {
    re.initPlugin(init, .{
        .requiredVersion = .{
            .gameName = "RE9",
        },
        // .onPreApplicationEntry = &.{
        //     .{ "UpdateBehavior", onUpdate },
        // },
        .onDeviceReset = onDeviceReset,
        .onImGuiDrawUI = struct {
            fn func(data: *re.API_C.REFImGuiFrameCbData) void {
                ui.draw(data) catch |e| {
                    log.err("Error in UI draw: {}", .{e});
                };
            }
        }.func,
    });
}

pub fn DllMain(
    hinstDLL: windows.HINSTANCE,
    fdwReason: windows.DWORD,
    lpReserved: windows.LPVOID,
) callconv(.winapi) windows.BOOL {
    _ = hinstDLL;
    _ = lpReserved;

    switch (fdwReason) {
        win32.system.system_services.DLL_PROCESS_ATTACH => {
            g.attach();
        },
        win32.system.system_services.DLL_PROCESS_DETACH => {},
        else => {},
    }

    return .TRUE;
}
