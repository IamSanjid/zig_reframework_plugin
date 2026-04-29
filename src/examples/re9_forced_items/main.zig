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

const ItemCategory = re.sdk.ManagedObject;

pub const Items = struct {
    categories: std.AutoHashMap(ItemCategory, [:0]const u8),
    catalog: std.AutoHashMap(ItemCategory, std.ArrayList(ItemDetails)),

    fn init(allocator: std.mem.Allocator) Items {
        return Items{
            .categories = .init(allocator),
            .catalog = .init(allocator),
        };
    }

    fn reset(self: *Items, allocator: std.mem.Allocator) void {
        var details = self.catalog.valueIterator();
        while (details.next()) |items| {
            for (items.items) |item| {
                allocator.free(item.name);
                allocator.free(item.caption);
            }
            items.clearRetainingCapacity();
        }
        self.catalog.clearRetainingCapacity();
    }

    fn deinit(self: *Items, allocator: std.mem.Allocator) void {
        self.categories.deinit();
        var details = self.catalog.valueIterator();
        while (details.next()) |items| {
            for (items.items) |item| {
                allocator.free(item.name);
                allocator.free(item.caption);
            }
            items.deinit(allocator);
        }
        self.catalog.deinit();
    }
};

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

    fn init(init_api: re.Api) !void {
        api = init_api;
        g.sdk = try api.verifiedSdk(verified_sdk_spec);
        g.tdb = re.sdk.getTdb(.fo(g.sdk)) orelse return error.TdbNotFound;
    }

    fn attach() void {
        allocator = debug_allocator.allocator();
        threaded = .init(allocator, .{});
        io = threaded.io();
        interop_cache = .init(allocator, io);
        items = .init(allocator);
    }

    fn reset() void {
        items.deinit(allocator);

        interop_cache.deinit();
        threaded.deinit();
        _ = debug_allocator.detectLeaks();
        _ = debug_allocator.deinit();
    }
};

fn tdbGetMethod(tdb: re.sdk.Tdb, comptime type_name: [:0]const u8, comptime method_sig: [:0]const u8) !?interop.MethodMetadata {
    const type_def = tdb.findType(.fo(g.sdk), type_name) orelse return null;
    const metadata = try g.interop_cache.getOrCacheMethodMetadata(.fo(g.sdk), type_def, method_sig);
    return metadata;
}

fn populateItemInfo() !void {
    g.api.lockLua();
    defer g.api.unlockLua();

    const item_category_typedef = g.tdb.findType(.fo(g.sdk), "app.ItemCategory") orelse return error.ItemCategoryTypeNotFound;
    {
        const fields_len = item_category_typedef.getNumFields(.fo(g.sdk));
        var item_category_fields = try std.ArrayList(re.sdk.Field).initCapacity(g.allocator, fields_len);
        defer item_category_fields.deinit(g.allocator);

        const item_category_fields_slice = try item_category_fields.addManyAsSlice(g.allocator, fields_len);
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

    const item_mgr = re.sdk.getManagedSingleton(.fo(g.sdk), "app.ItemManager") orelse return error.ItemManagerNotFound;
    const item_catalog = try g.interop_cache.getField(item_mgr, ._ItemCatalog, re.sdk.ManagedObject, .fo(g.sdk));

    // ValueType -> app.ConcurrentCatalogDictionary`2.ValueCollection<app.ItemID,app.ItemDetailData>
    // get_Values() -> ValueType -> toArray() -> SystemArray(ItemDetailData) -> GetValue(int) -> ItemDetailData
    const values_collection = try g.interop_cache.callMethod(
        item_catalog,
        "get_Values",
        .{},
        .{ .type = ?interop.ValueType },
        .fo(g.sdk),
        .{},
    );

    if (values_collection) |collection| {
        defer collection.deinit(g.allocator);
        log.debug("ItemCatalog ValueCollection: {any}", .{collection.data});
        if (collection.call(
            "toArray()",
            .{},
            .{ .type = SystemArray },
            &g.interop_cache,
            .fo(g.sdk),
            .{},
        )) |values| {
            g.items.reset(g.allocator);
            const len = try values.call(.GetLength, .fo(g.sdk), .{0});
            log.debug("ItemCatalog Values: {}", .{len});

            var unknowns: u32 = 0;
            for (0..@intCast(len)) |i| {
                const item_detail_mo = (try values.call(.GetValue, .fo(g.sdk), .{i})) orelse
                    return error.ItemDetailDataNotFound;

                const item_detail = try ItemDetailData.init(&g.interop_cache, .fo(g.sdk), item_detail_mo);

                const id = item_detail.get(._ItemID, .fo(g.sdk)) catch continue;
                const item_catagoery = item_detail.get(._ItemCategory, .fo(g.sdk)) catch continue;

                _ = g.items.categories.get(item_catagoery) orelse {
                    log.warn("Not known Category: 0x{x}", .{@intFromPtr(item_catagoery.raw)});
                };

                const name_message_id = item_detail.get(._NameMessageId, .fo(g.sdk)) catch continue;
                defer name_message_id.deinit(g.allocator);
                const caption_message_id = item_detail.get(._CaptionMessageId, .fo(g.sdk)) catch continue;

                const name_message = g.interop_cache.callStaticMethod(
                    "via.gui.message",
                    "get(System.Guid)",
                    .{},
                    .{ .type = interop.SystemStringView },
                    .fo(g.sdk),
                    .{name_message_id},
                ) catch continue;
                const caption_message = g.interop_cache.callStaticMethod(
                    "via.gui.message",
                    "get(System.Guid)",
                    .{},
                    .{ .type = interop.SystemStringView },
                    .fo(g.sdk),
                    .{caption_message_id},
                ) catch continue;

                var name_message_utf8 = try std.unicode.utf16LeToUtf8AllocZ(g.allocator, name_message.data);
                var caption_message_utf8 = try std.unicode.utf16LeToUtf8AllocZ(g.allocator, caption_message.data);

                if (name_message_utf8.len == 0 and caption_message_utf8.len == 0) {
                    unknowns += 1;
                    name_message_utf8 = try std.fmt.allocPrintSentinel(g.allocator, "UnknownName_{}", .{i}, 0);
                    caption_message_utf8 = try std.fmt.allocPrintSentinel(g.allocator, "UnknownCaption_{}", .{i}, 0);
                }
                const slot_capacity_data = item_detail.get(._SlotCapacityData, .fo(g.sdk)) catch continue;

                const items_entry = try g.items.catalog.getOrPut(item_catagoery);
                if (!items_entry.found_existing) {
                    items_entry.value_ptr.* = .empty;
                }

                try items_entry.value_ptr.append(g.allocator, .{
                    .id = id,
                    .category = item_catagoery,
                    .name = name_message_utf8,
                    .caption = caption_message_utf8,
                    .base_capacity = slot_capacity_data.get(._BaseCapacity, .fo(g.sdk)) catch continue,
                    .base_item_box_capacity = slot_capacity_data.get(._BaseItemBoxCapacity, .fo(g.sdk)) catch continue,
                });
            }

            log.debug("Collected Unknown Items: {}", .{unknowns});
            return;
        } else |_| {}
    }

    log.warn("Couldn't get the items details from catalog array route.", .{});

    const item_id_typedef = g.tdb.findType(.fo(g.sdk), "app.ItemID") orelse return error.ItemIdTypeNotFound;
    var item_ids: std.ArrayList(struct { [:0]const u8, re.sdk.ManagedObject }) = .empty;
    defer item_ids.deinit(g.allocator);
    {
        const fields_len = item_id_typedef.getNumFields(.fo(g.sdk));

        var item_id_fields = try std.ArrayList(re.sdk.Field).initCapacity(g.allocator, fields_len);
        defer item_id_fields.deinit(g.allocator);

        const item_id_fields_slice = try item_id_fields.addManyAsSlice(g.allocator, fields_len);
        const fields = try item_id_typedef.getFields(.fo(g.sdk), item_id_fields_slice);

        item_ids = try .initCapacity(g.allocator, fields_len);

        for (fields) |field| {
            const field_type = field.getType(.fo(g.sdk)) orelse continue;
            if (!field.isStatic(.fo(g.sdk)) or field_type.raw != item_id_typedef.raw) continue;

            const name = field.getName(.fo(g.sdk)) orelse continue;
            const data: *?*anyopaque = @ptrCast(@alignCast(field.getDataRaw(.fo(g.sdk), null, false) orelse continue));
            const field_value = interop.defaultToZigInterop(re.sdk.ManagedObject)(
                @constCast(&g.sdk),
                &g.interop_cache,
                field_type,
                data,
            ) catch continue;

            try item_ids.append(g.allocator, .{ name, field_value });
        }
    }

    g.items.reset(g.allocator);

    var unknowns: u32 = 0;
    for (item_ids.items, 0..) |item_id, i| {
        const item_detail = g.interop_cache.callMethod(
            item_catalog,
            "getValue",
            .{},
            .{ .type = ItemDetailData },
            .fo(g.sdk),
            .{ item_id.@"1", null },
        ) catch continue;

        const id = item_detail.get(._ItemID, .fo(g.sdk)) catch continue;
        const item_catagoery = item_detail.get(._ItemCategory, .fo(g.sdk)) catch continue;

        _ = g.items.categories.get(item_catagoery) orelse {
            log.warn("Not known Category: 0x{x}", .{@intFromPtr(item_catagoery.raw)});
        };

        const name_message_id = item_detail.get(._NameMessageId, .fo(g.sdk)) catch continue;
        defer name_message_id.deinit(g.allocator);
        const caption_message_id = item_detail.get(._CaptionMessageId, .fo(g.sdk)) catch continue;

        const name_message = g.interop_cache.callStaticMethod(
            "via.gui.message",
            "get(System.Guid)",
            .{},
            .{ .type = interop.SystemStringView },
            .fo(g.sdk),
            .{name_message_id},
        ) catch continue;
        const caption_message = g.interop_cache.callStaticMethod(
            "via.gui.message",
            "get(System.Guid)",
            .{},
            .{ .type = interop.SystemStringView },
            .fo(g.sdk),
            .{caption_message_id},
        ) catch continue;

        var name_message_utf8 = try std.unicode.utf16LeToUtf8AllocZ(g.allocator, name_message.data);
        var caption_message_utf8 = try std.unicode.utf16LeToUtf8AllocZ(g.allocator, caption_message.data);

        if (name_message_utf8.len == 0 and caption_message_utf8.len == 0) {
            unknowns += 1;
            name_message_utf8 = try std.fmt.allocPrintSentinel(g.allocator, "UnknownName_{}", .{i}, 0);
            caption_message_utf8 = try std.fmt.allocPrintSentinel(g.allocator, "UnknownCaption_{}", .{i}, 0);
        }
        const slot_capacity_data = item_detail.get(._SlotCapacityData, .fo(g.sdk)) catch continue;

        const items_entry = try g.items.catalog.getOrPut(item_catagoery);
        if (!items_entry.found_existing) {
            items_entry.value_ptr.* = .empty;
        }

        try items_entry.value_ptr.append(g.allocator, .{
            .id = id,
            .category = item_catagoery,
            .name = name_message_utf8,
            .caption = caption_message_utf8,
            .base_capacity = slot_capacity_data.get(._BaseCapacity, .fo(g.sdk)) catch continue,
            .base_item_box_capacity = slot_capacity_data.get(._BaseItemBoxCapacity, .fo(g.sdk)) catch continue,
        });
    }
}

fn onStart() !void {
    try populateItemInfo();
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
