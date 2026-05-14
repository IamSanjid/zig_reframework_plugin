const std = @import("std");
const root = @import("root");

const re = @import("reframework");

const cimgui = @import("cimgui");
const cimgui_dll = @import("cimgui_dll.zig");

const managed_types = @import("managed_types.zig");

const interop = re.interop;

const g = root.g;

const log = std.log.scoped(.re9_forced_ui);

const color_active = 0xfff4853d;
const color_warning: cimgui.ImVec4 = .{ .x = 1.0, .y = 1.0, .z = 0.0, .w = 1.0 };

// to match field names, keep tags in PascalCase
const ItemStockChangedEventTypeTag = enum {
    Default,
    Discard,
    Reloaded,
    Unloaded,
    Switched,
    Moved,
    Craft,
    Backup,
    Missable,
    Append,
    CarryOver,
};

const ItemLoadingTypeTag = enum {
    Auto,
    None,
    TypeA,
    TypeB,
};

const InventoryType = enum {
    Hand,
    ItemBox,
};

const u = struct {
    var show_window: bool = true;

    var remove_item_event_type: ItemStockChangedEventTypeTag = .Default;
    // var add_loading_type: ItemLoadingTypeTag = .Auto;
    var add_item_acquire_options: managed_types.InventoryAcquireItemOptions = .default;
    var add_item_event_type: ItemStockChangedEventTypeTag = .Default;

    // Items Catalog configs
    var item_catalog_fliter_category: ?managed_types.ItemCategory = null;
    var show_unknown_items: bool = false;
    var add_to_inventory: InventoryType = .Hand;

    // Save configs
    var manual_save_slot_selection_method: managed_types.SaveSlotSelectionMethod = .empty_or_oldest;

    // level flow configs
    var flow_progressive_number: i32 = 0;
    var owner_name_search_buf: [512:0]u8 = undefined;
    var action_type_search_buf: [512:0]u8 = undefined;
    var owner_name_search: ?[]const u8 = null;
    var action_type_search: ?[]const u8 = null;
    var read_flow_progressive_number: ?i32 = null;
    var filter_name_hash: u32 = 0;
    var filter_name_hash_count: i32 = 0;

    var scope: interop.Scope = undefined;

    fn init() !void {
        scope = g.interop_cache.newScope(g.allocator);
    }
};

inline fn getItemStockChangedEventType(
    from: ItemStockChangedEventTypeTag,
    scope: *interop.Scope,
) !managed_types.ItemStockChangedEventType {
    const ItemStockChangedEventTypeT = try g.interop_cache.resolve(
        managed_types.ItemStockChangedEventType.fullTypeName(),
        g.tdb,
        .fo(g.sdk),
    );
    const type_def = ItemStockChangedEventTypeT.type_def_metadata.def;
    return scope.getStaticFieldFromTypeDef(
        type_def,
        @tagName(from),
        managed_types.ItemStockChangedEventType,
        null,
        .fo(g.sdk),
    );
}

inline fn getInventory(from: InventoryType) *const root.InvenotryManagement {
    switch (from) {
        InventoryType.Hand => return &g.player.?.hand_inventory,
        InventoryType.ItemBox => return &g.player.?.item_box_inventory,
    }
}

// its safe because only one thread should be callin the draw function
var label_buf: [128]u8 = undefined;

fn drawInventory(str_id: [*c]const u8, inv: *const root.InvenotryManagement) !void {
    const items = inv.itemsSlice();
    if (items.len == 0) {
        cimgui_dll.igText("Empty.");
        return;
    }

    if (!cimgui_dll.igBeginTable(str_id, 6, cimgui.ImGuiTableFlags_Borders | cimgui.ImGuiTableFlags_Resizable, .{}, 0.0)) {
        return;
    }
    defer cimgui_dll.igEndTable();

    cimgui_dll.igTableSetupColumn("Name", cimgui.ImGuiTableColumnFlags_WidthStretch, 50.0, 0);
    cimgui_dll.igTableSetupColumn("Stock", cimgui.ImGuiTableColumnFlags_WidthStretch, 20.0, 0);
    cimgui_dll.igTableSetupColumn("Stock Cap", cimgui.ImGuiTableColumnFlags_WidthStretch, 20.0, 0);
    cimgui_dll.igTableSetupColumn("Loading Type", cimgui.ImGuiTableColumnFlags_WidthStretch, 30.0, 0);
    cimgui_dll.igTableSetupColumn("Category", cimgui.ImGuiTableColumnFlags_WidthStretch, 50.0, 0);
    cimgui_dll.igTableSetupColumn("Action", cimgui.ImGuiTableColumnFlags_WidthStretch, 100.0, 0);

    cimgui_dll.igTableHeadersRow();

    for (items, 0..) |item, i| {
        cimgui_dll.igTableNextRow(0, 0.0);

        const detail = item.detail_data;

        _ = cimgui_dll.igTableNextColumn();
        cimgui_dll.igText(detail.name);

        _ = cimgui_dll.igTableNextColumn();
        cimgui_dll.igText("%d", item.stock);

        _ = cimgui_dll.igTableNextColumn();
        cimgui_dll.igText("%d", item.stock_capacity);

        _ = cimgui_dll.igTableNextColumn();
        cimgui_dll.igText("%s", @tagName(item.loading_type).ptr);

        _ = cimgui_dll.igTableNextColumn();
        const category_name = g.items.categories.get(detail.category) orelse "Unknown";
        cimgui_dll.igText(category_name);

        _ = cimgui_dll.igTableNextColumn();

        const remove_btn_label = try std.fmt.bufPrintSentinel(&label_buf, "Remove##0x{x}-{}", .{ @intFromPtr(item.key.raw), i }, 0);
        if (cimgui_dll.igButton(remove_btn_label, .{})) {
            const evt = try getItemStockChangedEventType(u.remove_item_event_type, &u.scope);
            _ = try inv.consumeStock(&u.scope, item.key, item.stock, evt);
            // _ = try inv.removePanel(&u.scope, item.key, evt);
            return; // important to return because old items slice is now invalid after mutation
        }
        if (cimgui_dll.igIsItemHovered(0)) {
            cimgui_dll.igSetTooltip("Removes all of this item from the inventory.");
        }

        if (item.stock_capacity > item.stock) {
            cimgui_dll.igSameLine(0, -1.0);

            const available_space = item.stock_capacity - item.stock;
            const add_btn_label = try std.fmt.bufPrintSentinel(&label_buf, "Add {}##0x{x}-{}", .{
                available_space,
                @intFromPtr(item.key.raw),
                i,
            }, 0);

            if (cimgui_dll.igButton(add_btn_label, .{})) {
                // add available space items
                const evt = try getItemStockChangedEventType(u.add_item_event_type, &u.scope);
                _ = try inv.mergeOrAdd(&u.scope, detail.id, available_space, true, u.add_item_acquire_options, evt);
                return; // important to return because old items slice is now invalid after mutation
            }
        }
    }
}

fn drawPlayerInventory() !void {
    if (!cimgui_dll.igBeginTabBar("##inventory_tab", cimgui.ImGuiTabBarFlags_NoCloseWithMiddleMouseButton)) {
        return;
    }
    defer cimgui_dll.igEndTabBar();
    if (cimgui_dll.igBeginTabItem("Hand", null, cimgui.ImGuiTabItemFlags_NoCloseWithMiddleMouseButton)) {
        defer cimgui_dll.igEndTabItem();

        try drawInventory("##hand_items", &g.player.?.hand_inventory);
    }
    if (cimgui_dll.igBeginTabItem("Item Box", null, cimgui.ImGuiTabItemFlags_NoCloseWithMiddleMouseButton)) {
        defer cimgui_dll.igEndTabItem();

        try drawInventory("##item_box_items", &g.player.?.item_box_inventory);
    }
}

fn drawPickups() !void {
    cimgui_dll.igSameLine(0, -1.0);

    if (!cimgui_dll.igBeginTable("##item_catalog_table", 4, cimgui.ImGuiTableFlags_Borders | cimgui.ImGuiTableFlags_Resizable, .{}, 0.0)) {
        return;
    }
    defer cimgui_dll.igEndTable();

    cimgui_dll.igTableSetupColumn("Name", cimgui.ImGuiTableColumnFlags_WidthStretch, 50.0, 0);
    cimgui_dll.igTableSetupColumn("Description", cimgui.ImGuiTableColumnFlags_WidthStretch, 100.0, 0);
    cimgui_dll.igTableSetupColumn("Category", cimgui.ImGuiTableColumnFlags_WidthStretch, 50.0, 0);
    cimgui_dll.igTableSetupColumn("Action", cimgui.ImGuiTableColumnFlags_WidthStretch, 100.0, 0);

    cimgui_dll.igTableHeadersRow();

    var items_local_id: i32 = 0;

    var iter = g.item_pickups.map.valueIterator();
    while (iter.next()) |pickups| {
        for (pickups.items) |pickup_detail| {
            defer items_local_id += 1;
            const item = pickup_detail.detail;

            cimgui_dll.igTableNextRow(0, 0.0);

            _ = cimgui_dll.igTableNextColumn();
            cimgui_dll.igText(item.name);
            if (cimgui_dll.igIsItemHovered(0)) {
                cimgui_dll.igSetTooltip(
                    "ID: 0x%x\nBase Item Box Capacity: %d\nBase Capacity: %d",
                    @intFromPtr(item.id.raw),
                    item.base_item_box_capacity,
                    item.base_capacity,
                );
            }

            _ = cimgui_dll.igTableNextColumn();
            cimgui_dll.igText(item.caption);
            if (cimgui_dll.igIsItemHovered(0)) {
                cimgui_dll.igSetTooltip(
                    "ID: 0x%x\nBase Item Box Capacity: %d\nBase Capacity: %d",
                    @intFromPtr(item.id.raw),
                    item.base_item_box_capacity,
                    item.base_capacity,
                );
            }

            _ = cimgui_dll.igTableNextColumn();
            const category_name = g.items.categories.get(item.category) orelse "Unknown";
            cimgui_dll.igText(category_name);

            _ = cimgui_dll.igTableNextColumn();
            const btn_label = try std.fmt.bufPrintSentinel(
                &label_buf,
                "Pickup##0x{x}-{}",
                .{ @intFromPtr(item.id.raw), items_local_id },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                try g.performPickup(item.id);
                return; // new-frame, just in case old items slice might be invalid after mutation
            }
        }
    }
}

fn drawItemCatalogCategories() void {
    if (u.item_catalog_fliter_category == null) {
        cimgui_dll.igPushStyleColor_U32(cimgui.ImGuiCol_Button, color_active);
        cimgui_dll.igPushStyleColor_U32(cimgui.ImGuiCol_ButtonHovered, color_active);
        _ = cimgui_dll.igButton("All", .{});
        cimgui_dll.igPopStyleColor(2);
    } else {
        if (cimgui_dll.igButton("All", .{})) {
            u.item_catalog_fliter_category = null;
        }
    }
    cimgui_dll.igSameLine(0, -1.0);

    var categories = g.items.categoriesIterator();
    while (categories.next()) |entry| {
        var active = false;
        if (u.item_catalog_fliter_category) |selected| {
            if (selected.raw == entry.category.raw) {
                cimgui_dll.igPushStyleColor_U32(cimgui.ImGuiCol_Button, color_active);
                cimgui_dll.igPushStyleColor_U32(cimgui.ImGuiCol_ButtonHovered, color_active);
                active = true;
            }
        }

        if (cimgui_dll.igButton(entry.name, .{})) {
            u.item_catalog_fliter_category = entry.category;
        }

        if (active) {
            cimgui_dll.igPopStyleColor(2);
        }

        cimgui_dll.igSameLine(0, -1.0);
    }
    cimgui_dll.igNewLine();
}

fn drawItemCatalog() !void {
    _ = cimgui_dll.igCheckbox("Show unknown items", &u.show_unknown_items);

    drawMultiChoiceFrom(InventoryType, "Add to:", &u.add_to_inventory);
    cimgui_dll.igSeparator();

    drawItemCatalogCategories();
    cimgui_dll.igSeparator();

    if (!cimgui_dll.igBeginTable(
        "##item_catalog_table",
        4,
        cimgui.ImGuiTableFlags_Borders | cimgui.ImGuiTableFlags_Resizable,
        .{},
        0.0,
    )) {
        return;
    }
    defer cimgui_dll.igEndTable();

    cimgui_dll.igTableSetupColumn("Name", cimgui.ImGuiTableColumnFlags_WidthStretch, 50.0, 0);
    cimgui_dll.igTableSetupColumn("Description", cimgui.ImGuiTableColumnFlags_WidthStretch, 100.0, 0);
    cimgui_dll.igTableSetupColumn("Category", cimgui.ImGuiTableColumnFlags_WidthStretch, 50.0, 0);
    cimgui_dll.igTableSetupColumn("Action", cimgui.ImGuiTableColumnFlags_WidthStretch, 100.0, 0);

    cimgui_dll.igTableHeadersRow();

    var items_local_id: i32 = 0;

    var iter = try g.items.iterator(&u.scope);
    defer u.scope.reset();
    while (try iter.next()) |item| {
        if (u.item_catalog_fliter_category) |selected| {
            if (item.category.raw != selected.raw) {
                continue;
            }
        }
        if (!u.show_unknown_items and std.ascii.startsWithIgnoreCase(item.name, "Unknown")) {
            continue;
        }
        defer items_local_id += 1;

        cimgui_dll.igTableNextRow(0, 0.0);

        _ = cimgui_dll.igTableNextColumn();
        cimgui_dll.igText(item.name);
        if (cimgui_dll.igIsItemHovered(0)) {
            cimgui_dll.igSetTooltip(
                "ID: 0x%x\nBase Item Box Capacity: %d\nBase Capacity: %d",
                @intFromPtr(item.id.raw),
                item.base_item_box_capacity,
                item.base_capacity,
            );
        }

        _ = cimgui_dll.igTableNextColumn();
        cimgui_dll.igText(item.caption);
        if (cimgui_dll.igIsItemHovered(0)) {
            cimgui_dll.igSetTooltip(
                "ID: 0x%x\nBase Item Box Capacity: %d\nBase Capacity: %d",
                @intFromPtr(item.id.raw),
                item.base_item_box_capacity,
                item.base_capacity,
            );
        }

        _ = cimgui_dll.igTableNextColumn();
        const category_name = g.items.categories.get(item.category) orelse "Unknown";
        cimgui_dll.igText(category_name);

        _ = cimgui_dll.igTableNextColumn();
        const add_btn_label = try std.fmt.bufPrintSentinel(
            &label_buf,
            "Add##0x{x}-{}",
            .{ @intFromPtr(item.id.raw), items_local_id },
            0,
        );
        if (cimgui_dll.igButton(add_btn_label, .{})) {
            // add item
            const inv = getInventory(u.add_to_inventory);
            const evt = try getItemStockChangedEventType(u.add_item_event_type, &u.scope);
            _ = try inv.mergeOrAdd(&u.scope, item.id, 1, true, u.add_item_acquire_options, evt);
            return; // new-frame, just in case old items slice might be invalid after mutation
        }
        if (item.base_capacity > 1) {
            cimgui_dll.igSameLine(0, -1.0);
            const add_max_btn_lbl = try std.fmt.bufPrintSentinel(
                &label_buf,
                "Add {}##0x{x}-{}",
                .{ item.base_capacity, @intFromPtr(item.id.raw), items_local_id },
                0,
            );
            if (cimgui_dll.igButton(add_max_btn_lbl, .{})) {
                // add max items
                const inv = getInventory(u.add_to_inventory);
                const evt = try getItemStockChangedEventType(u.add_item_event_type, &u.scope);
                _ = try inv.mergeOrAdd(&u.scope, item.id, item.base_capacity, true, u.add_item_acquire_options, evt);
                return; // new-frame, just in case old items slice might be invalid after mutation
            }
        }
    }
}

fn drawObjectives() !void {
    const objectives = g.player.?.objective_mg.objectivesSlice();
    if (objectives.len == 0) {
        cimgui_dll.igText("No objectives.");
        return;
    }

    cimgui_dll.igTextColored(color_warning, "Actions are useless, these don't really update any in-game progress, only updates the UI." ++
        "It's mainly there to track objectives even during cutscenes :).");

    if (!cimgui_dll.igBeginTable("##objectives_table", 5, cimgui.ImGuiTableFlags_Borders | cimgui.ImGuiTableFlags_Resizable, .{}, 0.0)) {
        return;
    }
    defer cimgui_dll.igEndTable();

    cimgui_dll.igTableSetupColumn("ID", cimgui.ImGuiTableColumnFlags_WidthStretch, 30.0, 0);
    cimgui_dll.igTableSetupColumn("Parent ID", cimgui.ImGuiTableColumnFlags_WidthStretch, 30.0, 0);
    cimgui_dll.igTableSetupColumn("Description", cimgui.ImGuiTableColumnFlags_WidthStretch, 100.0, 0);
    cimgui_dll.igTableSetupColumn("Achieved", cimgui.ImGuiTableColumnFlags_WidthStretch, 30.0, 0);
    cimgui_dll.igTableSetupColumn("Action", cimgui.ImGuiTableColumnFlags_WidthStretch, 100.0, 0);

    cimgui_dll.igTableHeadersRow();

    for (objectives, 0..) |objective, i| {
        cimgui_dll.igTableNextRow(0, 0.0);

        _ = cimgui_dll.igTableNextColumn();
        cimgui_dll.igText("0x%x", @intFromPtr(objective.id.raw));

        _ = cimgui_dll.igTableNextColumn();
        cimgui_dll.igText("0x%x", @intFromPtr(objective.parent_id.raw));

        _ = cimgui_dll.igTableNextColumn();
        cimgui_dll.igText(objective.message);

        _ = cimgui_dll.igTableNextColumn();
        cimgui_dll.igText(if (objective.is_achieved) "Yes" else "No");

        _ = cimgui_dll.igTableNextColumn();
        const achieve_btn_label = try std.fmt.bufPrintSentinel(
            &label_buf,
            "Achieve##0x{x}-{}",
            .{ @intFromPtr(objective.id.raw), i },
            0,
        );
        if (cimgui_dll.igButton(achieve_btn_label, .{})) {
            try root.ObjectiveManagement.requestAchieveObjective(&u.scope, objective.id, false);
            return; // new-frame
        }
        cimgui_dll.igSameLine(0.0, -1.0);
        const set_objective_btn_label = try std.fmt.bufPrintSentinel(
            &label_buf,
            "Set##0x{x}-{}",
            .{ @intFromPtr(objective.id.raw), i },
            0,
        );
        if (cimgui_dll.igButton(set_objective_btn_label, .{})) {
            try root.ObjectiveManagement.requestSetObjective(&u.scope, objective.id, false);
            return; // new-frame
        }
        if (objective.max_count > 0 and objective.count < objective.max_count) {
            cimgui_dll.igSameLine(0.0, -1.0);
            const count_objective_btn_label = try std.fmt.bufPrintSentinel(
                &label_buf,
                "Add Count##0x{x}-{}",
                .{ @intFromPtr(objective.id.raw), i },
                0,
            );
            if (cimgui_dll.igButton(count_objective_btn_label, .{})) {
                const is_open_map = root.ObjectiveManagement.isOpenMap(&u.scope, objective.id) catch false;
                try root.ObjectiveManagement.requestCountObjective(&u.scope, objective.id, false, is_open_map);
                return; // new-frame
            }
        }
    }
}

fn drawGameJumps() !void {
    if (cimgui_dll.igButton("Skip Chapter Forcefully", .{})) {
        try g.scene_transition_manager.call(.requestMainGameJump, &u.scope, .fo(g.sdk), .{false});
        return; // new-frame
    }
    if (cimgui_dll.igIsItemHovered(0)) {
        cimgui_dll.igSetTooltip(
            "It's recommended to use this only when there's no Game Jumps available.\n" ++
                "For some chapters character might fall through and can't continue, inventory might be empty.",
        );
    }

    const game_jump_actions = g.player.?.game_jump_actions.items;

    if (!cimgui_dll.igBeginTable("##game_jumps_table", 4, cimgui.ImGuiTableFlags_Borders | cimgui.ImGuiTableFlags_Resizable, .{}, 0.0)) {
        return;
    }
    defer cimgui_dll.igEndTable();

    cimgui_dll.igTableSetupColumn("NameHash", cimgui.ImGuiTableColumnFlags_WidthStretch, 30.0, 0);
    cimgui_dll.igTableSetupColumn("Owner Name", cimgui.ImGuiTableColumnFlags_WidthStretch, 30.0, 0);
    cimgui_dll.igTableSetupColumn("Jump Data", cimgui.ImGuiTableColumnFlags_WidthStretch, 100.0, 0);
    cimgui_dll.igTableSetupColumn("Action", cimgui.ImGuiTableColumnFlags_WidthStretch, 100.0, 0);

    cimgui_dll.igTableHeadersRow();

    for (game_jump_actions, 0..) |game_jump_action, i| {
        cimgui_dll.igTableNextRow(0, 0.0);

        _ = cimgui_dll.igTableNextColumn();
        cimgui_dll.igText("%u", game_jump_action.name_hash);

        if (cimgui_dll.igIsItemHovered(0) and cimgui_dll.igIsMouseReleased_Nil(cimgui.ImGuiMouseButton_Right)) {
            const text = try std.fmt.bufPrintSentinel(&label_buf, "0x{x}", .{@intFromPtr(game_jump_action.owner_component.managed.raw)}, 0);
            cimgui_dll.igSetClipboardText(text.ptr);
        }

        _ = cimgui_dll.igTableNextColumn();
        cimgui_dll.igText(game_jump_action.owner_name);

        _ = cimgui_dll.igTableNextColumn();
        for (game_jump_action.jump_datas, 0..) |jump_data, j| {
            cimgui_dll.igText("[%d] Data:", j);
            cimgui_dll.igText("Level Id: %s", jump_data.level_id_str.ptr);
            if (!std.ascii.startsWithIgnoreCase(jump_data.jump_name, "Unknown"))
                cimgui_dll.igText("Jump Name: %s", jump_data.jump_name.ptr);
        }

        _ = cimgui_dll.igTableNextColumn();

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &label_buf,
                "Start##0x{x}-{}",
                .{ @intFromPtr(game_jump_action.owner_component.managed.raw), i },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                try g.btree_management.queueFlowBTreeAction(.start, game_jump_action.owner_component);
                return;
            }
            if (cimgui_dll.igIsItemHovered(0)) {
                cimgui_dll.igSetTooltip("Might cause crash, forcefully calls the action start function.");
            }
        }

        cimgui_dll.igSameLine(0.0, -1.0);

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &label_buf,
                "Start Native##0x{x}-{}",
                .{ @intFromPtr(game_jump_action.owner_component.managed.raw), i },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                try g.btree_management.queueFlowBTreeAction(.start_native, game_jump_action.owner_component);
                return;
            }
            if (cimgui_dll.igIsItemHovered(0)) {
                cimgui_dll.igSetTooltip("Uses the native function to start, might need an update for the plugin for updated vtable/function pointer offset" ++
                    "\nMight cause crash, forcefully calls the action start function.");
            }
        }

        {
            const next_btn_label = try std.fmt.bufPrintSentinel(
                &label_buf,
                "Next##0x{x}-{}",
                .{ @intFromPtr(game_jump_action.owner_component.managed.raw), i },
                0,
            );
            if (cimgui_dll.igButton(next_btn_label, .{})) {
                _ = try g.level_flow_manager.call(.sendNext, &u.scope, .fo(g.sdk), .{ game_jump_action.name_hash, null });
                return;
            }
            if (cimgui_dll.igIsItemHovered(0)) {
                cimgui_dll.igSetTooltip("Requests the next step for the level flow, different name hash means different level flow, press it multiple times to progress in-game.");
            }
        }

        cimgui_dll.igSameLine(0.0, -1.0);

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &label_buf,
                "Reset##0x{x}-{}",
                .{ @intFromPtr(game_jump_action.owner_component.managed.raw), i },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                _ = try g.level_flow_manager.call(.requestResetProgressiveNumber, &u.scope, .fo(g.sdk), .{game_jump_action.name_hash});
                return;
            }
            if (cimgui_dll.igIsItemHovered(0)) {
                cimgui_dll.igSetTooltip("Requests the owner level flow to reset, start from the first flow" ++
                    "\nMight make the level broken resulting unable to progress in-game.");
            }
        }
    }
}

fn leftLabelInputText(
    label: [*c]const u8,
    input_label: [*c]const u8,
    buf: [*c]u8,
    buf_size: usize,
    flags: cimgui.ImGuiInputTextFlags,
    input_width: f32,
) bool {
    const item_spacing = cimgui_dll.igGetStyle().*.ItemSpacing;

    var text_size: cimgui.ImVec2 = .{};
    cimgui_dll.igCalcTextSize(&text_size, label, null, false, -1.0);

    cimgui_dll.igText(label);
    cimgui_dll.igSameLine(0.0, -1.0);
    cimgui_dll.igSetNextItemWidth(input_width - text_size.x - item_spacing.x);
    return cimgui_dll.igInputText(input_label, buf, buf_size, flags, null, null);
}

fn drawLevelFlowsRange(level_flows: []managed_types.LevelFlowObject, start: usize, end: usize) !void {
    for (start..end) |i| {
        const flow_obj = level_flows[i];
        const flow_data = flow_obj.data orelse continue;
        const component = flow_obj.component;

        if (u.filter_name_hash != 0 and flow_obj.name_hash != u.filter_name_hash) {
            continue;
        }
        //const flow = flow_obj.component;
        if (u.owner_name_search) |search| {
            if (std.ascii.findIgnoreCase(flow_data.owner_name, search) == null) {
                continue;
            }
        }
        if (u.action_type_search) |search| {
            var found = false;
            for (flow_data.action_names) |action_name| {
                if (std.ascii.findIgnoreCase(action_name, search) != null) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                continue;
            }
        }

        cimgui_dll.igTableNextRow(0, 0.0);

        _ = cimgui_dll.igTableNextColumn();
        cimgui_dll.igText("%u", flow_obj.name_hash);
        if (cimgui_dll.igIsItemHovered(0) and cimgui_dll.igIsMouseReleased_Nil(cimgui.ImGuiMouseButton_Right)) {
            const copy_text = try std.fmt.bufPrintSentinel(&label_buf, "0x{x}", .{@intFromPtr(component.managed.raw)}, 0);
            cimgui_dll.igSetClipboardText(copy_text);
        }

        _ = cimgui_dll.igTableNextColumn();
        cimgui_dll.igText(flow_data.owner_name);

        _ = cimgui_dll.igTableNextColumn();
        for (0.., flow_data.action_names) |j, action_name| {
            cimgui_dll.igText("[%d] %s", j, action_name.ptr);
        }

        _ = cimgui_dll.igTableNextColumn();

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &label_buf,
                "Start##0x{x}-{}",
                .{ @intFromPtr(component.managed.raw), i },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                // try g.startFlowActions(component);
                try g.btree_management.queueFlowBTreeAction(.start, component);
                return;
            }
            if (cimgui_dll.igIsItemHovered(0)) {
                cimgui_dll.igSetTooltip("Might cause crash, forcefully calls the action start function.");
            }
        }

        cimgui_dll.igSameLine(0.0, -1.0);

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &label_buf,
                "Start Native##0x{x}-{}",
                .{ @intFromPtr(component.managed.raw), i },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                try g.btree_management.queueFlowBTreeAction(.start_native, component);
                return;
            }
            if (cimgui_dll.igIsItemHovered(0)) {
                cimgui_dll.igSetTooltip("Uses the native function to start, might need an update for the plugin for updated vtable/function pointer offset" ++
                    "\nMight cause crash, forcefully calls the action start function.");
            }
        }

        if (u.filter_name_hash != 0) continue;

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &label_buf,
                "Next##0x{x}-{}",
                .{ @intFromPtr(component.managed.raw), i },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                _ = try g.level_flow_manager.call(.sendNext, &u.scope, .fo(g.sdk), .{ flow_obj.name_hash, null });
                return;
            }
            if (cimgui_dll.igIsItemHovered(0)) {
                cimgui_dll.igSetTooltip("Requests the next step for the level flow, different name hash means different level flow, press it multiple times to progress in-game.");
            }
        }

        cimgui_dll.igSameLine(0.0, -1.0);

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &label_buf,
                "Set##0x{x}-{}",
                .{ @intFromPtr(flow_obj.component.managed.raw), i },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                try g.level_flow_manager.call(
                    .requestChangeProgressiveNumber,
                    &u.scope,
                    .fo(g.sdk),
                    .{ flow_obj.name_hash, u.flow_progressive_number },
                );
                return;
            }
            if (cimgui_dll.igIsItemHovered(0)) {
                cimgui_dll.igSetTooltip("Sets the progressive number to the inputted value in the Config section.\n" ++
                    "Can be used to skip or repeat certain sections if the flow supports it.\n" ++
                    "Usually you stop the flow and then set the progressive number again and again.");
            }
        }

        // line break

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &label_buf,
                "Reset##0x{x}-{}",
                .{ @intFromPtr(component.managed.raw), i },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                try g.level_flow_manager.call(.requestResetProgressiveNumber, &u.scope, .fo(g.sdk), .{flow_obj.name_hash});
                return;
            }
            if (cimgui_dll.igIsItemHovered(0)) {
                cimgui_dll.igSetTooltip("Requests the owner level flow to reset, start from the first flow" ++
                    "\nMight make the level broken resulting unable to progress in-game.");
            }
        }

        cimgui_dll.igSameLine(0.0, -1.0);

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &label_buf,
                "Stop##0x{x}-{}",
                .{ @intFromPtr(component.managed.raw), i },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                try g.level_flow_manager.call(.requestStopProgressive, &u.scope, .fo(g.sdk), .{flow_obj.name_hash});
                return;
            }
        }

        cimgui_dll.igSameLine(0.0, -1.0);

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &label_buf,
                "Read##0x{x}-{}",
                .{ @intFromPtr(component.managed.raw), i },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                u.read_flow_progressive_number = try g.level_flow_manager.call(
                    .getProgressiveNumber,
                    &u.scope,
                    .fo(g.sdk),
                    .{flow_obj.name_hash},
                );
                return;
            }
        }
    }
}

fn drawLevelFlows() !void {
    {
        if (cimgui_dll.igButton("Start All", .{})) {
            try g.level_flow_manager.call(.requestStartFlow, &u.scope, .fo(g.sdk), .{});
            return; // new-frame
        }
        cimgui_dll.igSameLine(0.0, -1.0);
        if (cimgui_dll.igButton("Reset All", .{})) {
            try g.level_flow_manager.call(.requestReset, &u.scope, .fo(g.sdk), .{});
            return; // new-frame
        }
        cimgui_dll.igSameLine(0.0, -1.0);
        if (cimgui_dll.igButton("Stop All", .{})) {
            try g.level_flow_manager.call(.requestStopFlow, &u.scope, .fo(g.sdk), .{});
            return; // new-frame
        }
    }

    {
        cimgui_dll.igText("Filter by NameHash:");

        if (u.filter_name_hash == 0) {
            cimgui_dll.igPushStyleColor_U32(cimgui.ImGuiCol_Button, color_active);
            cimgui_dll.igPushStyleColor_U32(cimgui.ImGuiCol_ButtonHovered, color_active);
            _ = cimgui_dll.igButton("All", .{});
            cimgui_dll.igPopStyleColor(2);
        } else {
            if (cimgui_dll.igButton("All", .{})) {
                u.filter_name_hash = 0;
            }
        }
        cimgui_dll.igSameLine(0, -1.0);

        var same_line_remaining: u32 = 5;

        var name_hashes = g.level_flow_managed_objects.name_hashes.iterator();
        var reset_filter_name_hash = u.filter_name_hash != 0;
        while (name_hashes.next()) |entry| {
            const name_hash = entry.key_ptr.*;
            const name_count = entry.value_ptr.*;

            var active = false;
            if (u.filter_name_hash != 0 and u.filter_name_hash == name_hash) {
                cimgui_dll.igPushStyleColor_U32(cimgui.ImGuiCol_Button, color_active);
                cimgui_dll.igPushStyleColor_U32(cimgui.ImGuiCol_ButtonHovered, color_active);
                active = true;
                reset_filter_name_hash = false;
            }

            const btn_label = try std.fmt.bufPrintSentinel(&label_buf, "{}", .{name_hash}, 0);
            if (cimgui_dll.igButton(btn_label, .{})) {
                if (u.filter_name_hash == name_hash) {
                    u.filter_name_hash = 0;
                } else {
                    u.filter_name_hash = name_hash;
                    u.filter_name_hash_count = name_count;
                }
            }

            if (active) {
                cimgui_dll.igPopStyleColor(2);
            }

            if (same_line_remaining > 0) {
                cimgui_dll.igSameLine(0, -1.0);
                same_line_remaining -= 1;
            } else {
                same_line_remaining = 6; // one less at start because of the "All" button
            }
        }
        if (reset_filter_name_hash) {
            u.filter_name_hash = 0;
            u.filter_name_hash_count = 0;
        }
        cimgui_dll.igNewLine();
    }

    {
        const item_spacing = cimgui_dll.igGetStyle().*.ItemSpacing;
        var avail: cimgui.ImVec2 = .{};
        cimgui_dll.igGetContentRegionAvail(&avail);
        const input_width: f32 = (avail.x * 0.5) - (item_spacing.x * 0.5);

        if (leftLabelInputText(
            "Owner Search",
            "##owner_name_search",
            &u.owner_name_search_buf,
            u.owner_name_search_buf.len,
            cimgui.ImGuiInputTextFlags_AutoSelectAll,
            input_width,
        )) {
            if (u.owner_name_search_buf[0] != 0) {
                u.owner_name_search = std.mem.sliceTo(u.owner_name_search_buf[0..], 0);
            } else {
                u.owner_name_search = null;
            }
        }

        cimgui_dll.igSameLine(0.0, -1.0);

        if (leftLabelInputText(
            "Action Search",
            "##action_type_search",
            &u.action_type_search_buf,
            u.action_type_search_buf.len,
            cimgui.ImGuiInputTextFlags_AutoSelectAll,
            input_width,
        )) {
            if (u.action_type_search_buf[0] != 0) {
                u.action_type_search = std.mem.sliceTo(u.action_type_search_buf[0..], 0);
            } else {
                u.action_type_search = null;
            }
        }
    }

    const level_flows = g.level_flow_managed_objects.collection.items;
    if (u.filter_name_hash != 0) {
        cimgui_dll.igText("Total flows: %d", u.filter_name_hash_count);
        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &label_buf,
                "Next##0x{x}-{}",
                .{ u.filter_name_hash, u.filter_name_hash_count },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                _ = try g.level_flow_manager.call(.sendNext, &u.scope, .fo(g.sdk), .{ u.filter_name_hash, null });
                return;
            }
            if (cimgui_dll.igIsItemHovered(0)) {
                cimgui_dll.igSetTooltip("Requests the next step for the level flow, different name hash means different level flow, press it multiple times to progress in-game.");
            }
        }

        cimgui_dll.igSameLine(0.0, -1.0);

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &label_buf,
                "Set##0x{x}-{}",
                .{ u.filter_name_hash, u.filter_name_hash_count },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                try g.level_flow_manager.call(
                    .requestChangeProgressiveNumber,
                    &u.scope,
                    .fo(g.sdk),
                    .{ u.filter_name_hash, u.flow_progressive_number },
                );
                return;
            }
            if (cimgui_dll.igIsItemHovered(0)) {
                cimgui_dll.igSetTooltip("Sets the progressive number to the inputted value in the Config section.\n" ++
                    "Can be used to skip or repeat certain sections if the flow supports it.\n" ++
                    "Usually you stop the flow and then set the progressive number again and again.");
            }
        }

        cimgui_dll.igSameLine(0.0, -1.0);

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &label_buf,
                "Reset##0x{x}-{}",
                .{ u.filter_name_hash, u.filter_name_hash_count },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                try g.level_flow_manager.call(.requestResetProgressiveNumber, &u.scope, .fo(g.sdk), .{u.filter_name_hash});
                return;
            }
        }

        cimgui_dll.igSameLine(0.0, -1.0);

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &label_buf,
                "Stop##0x{x}-{}",
                .{ u.filter_name_hash, u.filter_name_hash_count },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                try g.level_flow_manager.call(.requestStopProgressive, &u.scope, .fo(g.sdk), .{u.filter_name_hash});
                return;
            }
        }

        cimgui_dll.igSameLine(0.0, -1.0);

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &label_buf,
                "Read##0x{x}-{}",
                .{ u.filter_name_hash, u.filter_name_hash_count },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                u.read_flow_progressive_number = try g.level_flow_manager.call(
                    .getProgressiveNumber,
                    &u.scope,
                    .fo(g.sdk),
                    .{u.filter_name_hash},
                );
                return;
            }
            if (cimgui_dll.igIsItemHovered(0)) {
                cimgui_dll.igSetTooltip("Reads the progressive number for the level flow.");
            }
        }
    } else {
        cimgui_dll.igText("Total flows: %llu", level_flows.len);
    }

    if (u.read_flow_progressive_number) |number| {
        cimgui_dll.igText("Progressive Number: %d", number);
        cimgui_dll.igSameLine(0, -1.0);
        if (cimgui_dll.igButton("Clear##level_prog_number_clear", .{})) {
            u.read_flow_progressive_number = null;
            return; // new-frame
        }
    }

    if (!cimgui_dll.igBeginTable("##level_flow_table", 4, cimgui.ImGuiTableFlags_Borders | cimgui.ImGuiTableFlags_Resizable, .{}, 0.0)) {
        return;
    }
    defer cimgui_dll.igEndTable();

    cimgui_dll.igTableSetupColumn("Name Hash", cimgui.ImGuiTableColumnFlags_WidthStretch, 30.0, 0);
    cimgui_dll.igTableSetupColumn("Owner Name", cimgui.ImGuiTableColumnFlags_WidthStretch, 30.0, 0);
    cimgui_dll.igTableSetupColumn("Actions", cimgui.ImGuiTableColumnFlags_WidthStretch, 300.0, 0);
    cimgui_dll.igTableSetupColumn("Action", cimgui.ImGuiTableColumnFlags_WidthStretch, 100.0, 0);

    cimgui_dll.igTableHeadersRow();

    // Why clipper? Goal is to be below 1ms re-framework frame time.

    if (u.filter_name_hash != 0 and u.filter_name_hash_count <= 250) {
        // no need to use clipper if there's only a few items, also it causes some issues with the "All" button when filtering by name hash
        try drawLevelFlowsRange(level_flows, 0, level_flows.len);
        return;
    }

    const clipper: *cimgui.ImGuiListClipper = cimgui_dll.ImGuiListClipper_ImGuiListClipper();
    defer cimgui_dll.ImGuiListClipper_destroy(clipper);
    cimgui_dll.ImGuiListClipper_Begin(clipper, @intCast(level_flows.len), -1.0);
    defer cimgui_dll.ImGuiListClipper_End(clipper);

    while (cimgui_dll.ImGuiListClipper_Step(clipper)) {
        const start: usize = @intCast(clipper.DisplayStart);
        const end: usize = @intCast(clipper.DisplayEnd);

        try drawLevelFlowsRange(level_flows, start, end);
    }
}

fn drawMultiChoiceFrom(comptime T: type, label: [*c]const u8, current: *T) void {
    cimgui_dll.igText(label);

    cimgui_dll.igPushID_Str(label);
    defer cimgui_dll.igPopID();

    const tags = std.meta.tags(T);
    comptime var same_line_remainig = 5;
    inline for (tags.*, 0..) |tag, i| {
        var active = false;
        if (current.* == tag) {
            cimgui_dll.igPushStyleColor_U32(cimgui.ImGuiCol_Button, color_active);
            cimgui_dll.igPushStyleColor_U32(cimgui.ImGuiCol_ButtonHovered, color_active);
            active = true;
        }

        cimgui_dll.igPushID_Int(i);
        defer cimgui_dll.igPopID();
        if (cimgui_dll.igButton(@tagName(tag).ptr, .{})) {
            current.* = tag;
        }

        if (active) {
            cimgui_dll.igPopStyleColor(2);
        }

        if (i >= tags.len - 1) continue;

        if (same_line_remainig > 0) {
            cimgui_dll.igSameLine(0, -1.0);
            same_line_remainig -= 1;
        } else {
            same_line_remainig = 5;
        }
    }
}

fn drawConfig() void {
    drawMultiChoiceFrom(ItemStockChangedEventTypeTag, "Remove Item Event Type:", &u.remove_item_event_type);
    cimgui_dll.igSeparator();
    drawMultiChoiceFrom(managed_types.InventoryAcquireItemOptions, "Add Item Acquire Options:", &u.add_item_acquire_options);
    cimgui_dll.igSeparator();
    drawMultiChoiceFrom(ItemStockChangedEventTypeTag, "Add Item Event Type:", &u.add_item_event_type);
    cimgui_dll.igSeparator();
    drawMultiChoiceFrom(managed_types.SaveSlotSelectionMethod, "Manual Save Slot Selection:", &u.manual_save_slot_selection_method);
    cimgui_dll.igSeparator();
    {
        const add_step: i32 = 50;
        const add_step_fast: i32 = 500;
        _ = cimgui_dll.igInputScalar(
            "Level Flow Progressive Number",
            cimgui.ImGuiDataType_S32,
            &u.flow_progressive_number,
            &add_step,
            &add_step_fast,
            "%d",
            0,
        );
    }
}

const debug_behavior_tree = @import("debug_behavior_tree.zig");
pub fn draw(data: *re.API_C.REFImGuiFrameCbData) !void {
    try cimgui_dll.init();

    cimgui_dll.igSetCurrentContext(@ptrCast(@alignCast(data.context)));
    cimgui_dll.igSetAllocatorFunctions(
        @ptrCast(@alignCast(data.malloc_fn)),
        @ptrCast(@alignCast(data.free_fn)),
        data.user_data,
    );

    try debug_behavior_tree.draw();

    if (!u.show_window) {
        if (cimgui_dll.igCollapsingHeader_BoolPtr("RE9 Forced in Zig", null, 0)) {
            _ = cimgui_dll.igCheckbox("Show Window", &u.show_window);
        }
        return;
    }

    cimgui_dll.igSetNextItemOpen(true, cimgui.ImGuiCond_Once);
    defer cimgui_dll.igEnd();
    if (!cimgui_dll.igBegin("RE9 Forced in Zig", &u.show_window, cimgui.ImGuiWindowFlags_HorizontalScrollbar)) {
        return;
    }

    g.api.lockLua();
    defer g.api.unlockLua();

    if (g.items.categories.count() == 0 or g.player == null) {
        cimgui_dll.igText("Player context not initialized. Please load/reload a save and wait until the character is loaded.");
        return;
    }

    cimgui_dll.igTextColored(color_warning, "Warning: Modifying any of the states can cause instability and crashes. Always keep backup saves.");

    if (cimgui_dll.igButton("Refresh All", .{})) {
        try root.new();
        return; // new-frame
    }
    cimgui_dll.igSameLine(0, -1.0);
    if (cimgui_dll.igButton("Trigger Auto Save", .{})) {
        try g.triggerAutoSave();
    }
    if (cimgui_dll.igIsItemHovered(0)) {
        cimgui_dll.igSetTooltip("Triggers an auto save. Replaces newest auto save.");
    }
    cimgui_dll.igSameLine(0, -1.0);
    if (cimgui_dll.igButton("Trigger Manual Save", .{})) {
        try g.triggerManualSave(u.manual_save_slot_selection_method);
    }
    if (cimgui_dll.igIsItemHovered(0)) {
        cimgui_dll.igSetTooltip("Triggers a manual save, slot selection method can be choosen from Config section.\nAvoid `manual` slot selection method.");
    }
    cimgui_dll.igSameLine(0, -1.0);
    if (cimgui_dll.igButton("Restart from Last Save", .{})) {
        try g.scene_transition_manager.call(.requestMainGameJump, &u.scope, .fo(g.sdk), .{true});
        return; // new-frame
    }

    cimgui_dll.igSetNextItemOpen(false, cimgui.ImGuiCond_Once);
    if (cimgui_dll.igCollapsingHeader_BoolPtr("Config", null, 0)) {
        drawConfig();
    }

    cimgui_dll.igSeparatorText("Force Changes");

    if (!cimgui_dll.igBeginTabBar("##main_tab", cimgui.ImGuiTabBarFlags_NoCloseWithMiddleMouseButton)) {
        return;
    }
    defer cimgui_dll.igEndTabBar();

    if (cimgui_dll.igBeginTabItem("Inventory", null, cimgui.ImGuiTabItemFlags_NoCloseWithMiddleMouseButton)) {
        defer cimgui_dll.igEndTabItem();

        try drawPlayerInventory();
    }

    if (cimgui_dll.igBeginTabItem("Pickups", null, cimgui.ImGuiTabItemFlags_NoCloseWithMiddleMouseButton)) {
        defer cimgui_dll.igEndTabItem();

        try drawPickups();
    }

    if (cimgui_dll.igBeginTabItem("Items Catalog", null, cimgui.ImGuiTabItemFlags_NoCloseWithMiddleMouseButton)) {
        defer cimgui_dll.igEndTabItem();

        try drawItemCatalog();
    }

    if (cimgui_dll.igBeginTabItem("Objectives", null, cimgui.ImGuiTabItemFlags_NoCloseWithMiddleMouseButton)) {
        defer cimgui_dll.igEndTabItem();

        try drawObjectives();
    }

    if (cimgui_dll.igBeginTabItem("Game Jumps", null, cimgui.ImGuiTabItemFlags_NoCloseWithMiddleMouseButton)) {
        defer cimgui_dll.igEndTabItem();

        try drawGameJumps();
    }

    if (cimgui_dll.igBeginTabItem("Level Flows", null, cimgui.ImGuiTabItemFlags_NoCloseWithMiddleMouseButton)) {
        defer cimgui_dll.igEndTabItem();

        try drawLevelFlows();
    }
}

pub fn init() !void {
    try u.init();
    cimgui_dll.init() catch |e| {
        log.err("Failed to initialize cimgui_dll: {}", .{e});
    };
}
