const std = @import("std");
const root = @import("root");

const re = @import("reframework");

const cimgui = @import("cimgui");
const cimgui_dll = @import("cimgui_dll.zig");

const managed_types = @import("managed_types.zig");

const g = root.g;

const log = std.log.scoped(.re9_forced_items_ui);

const color_active = 0xfff4853d;

const u = struct {
    var current_category: ?managed_types.ItemCategory = null;
    var show_unknown_items: bool = false;
    var scope: ?re.interop.Scope = null;
};

fn drawCategories() void {
    if (u.current_category == null) {
        cimgui_dll.igPushStyleColor_U32(cimgui.ImGuiCol_Button, color_active);
        cimgui_dll.igPushStyleColor_U32(cimgui.ImGuiCol_ButtonHovered, color_active);
        _ = cimgui_dll.igButton("All", .{});
        cimgui_dll.igPopStyleColor(2);
    } else {
        if (cimgui_dll.igButton("All", .{})) {
            u.current_category = null;
        }
    }
    cimgui_dll.igSameLine(0, -1.0);

    var categories = g.items.categoriesIterator();
    while (categories.next()) |entry| {
        var active = false;
        if (u.current_category) |selected| {
            if (selected.raw == entry.category.raw) {
                cimgui_dll.igPushStyleColor_U32(cimgui.ImGuiCol_Button, color_active);
                cimgui_dll.igPushStyleColor_U32(cimgui.ImGuiCol_ButtonHovered, color_active);
                active = true;
            }
        }

        if (cimgui_dll.igButton(entry.name, .{})) {
            u.current_category = entry.category;
        }

        if (active) {
            cimgui_dll.igPopStyleColor(2);
        }

        cimgui_dll.igSameLine(0, -1.0);
    }
    cimgui_dll.igNewLine();
}

pub fn draw(data: *re.API_C.REFImGuiFrameCbData) !void {
    cimgui_dll.init() catch |e| {
        log.err("Dynamic cimgui initialization failed: {}", .{e});
        return;
    };

    cimgui_dll.igSetCurrentContext(@ptrCast(@alignCast(data.context)));
    cimgui_dll.igSetAllocatorFunctions(
        @ptrCast(@alignCast(data.malloc_fn)),
        @ptrCast(@alignCast(data.free_fn)),
        data.user_data,
    );

    cimgui_dll.igSetNextItemOpen(true, cimgui.ImGuiCond_Once);
    defer cimgui_dll.igEnd();
    if (!cimgui_dll.igBegin("RE9 Forced Items in Zig", null, cimgui.ImGuiWindowFlags_MenuBar)) {
        return;
    }
    // if (!cimgui_dll.igCollapsingHeader_BoolPtr("RE9 Forced Items in Zig", null, 0)) {
    //     return;
    // }

    g.api.lockLua();
    defer g.api.unlockLua();

    if (u.scope == null) {
        u.scope = g.interop_cache.newScope(g.allocator);
    }

    if (g.items.categories.count() == 0) {
        cimgui_dll.igText("Couldn't cache item info. Please load/reload a save.");
        return;
    }

    _ = cimgui_dll.igCheckbox("Show unknown items", &u.show_unknown_items);

    drawCategories();

    defer cimgui_dll.igEndTable();
    if (!cimgui_dll.igBeginTable("item_table", 4, cimgui.ImGuiTableFlags_Borders | cimgui.ImGuiTableFlags_Resizable, .{}, 0.0)) {
        return;
    }

    cimgui_dll.igTableSetupColumn("Name", cimgui.ImGuiTableColumnFlags_WidthStretch, 0.0, 0);
    cimgui_dll.igTableSetupColumn("Description", cimgui.ImGuiTableColumnFlags_WidthStretch, 0.0, 0);
    cimgui_dll.igTableSetupColumn("Category", cimgui.ImGuiTableColumnFlags_WidthStretch, 100.0, 0);
    cimgui_dll.igTableSetupColumn("Action", cimgui.ImGuiTableColumnFlags_WidthStretch, 200.0, 0);

    cimgui_dll.igTableHeadersRow();

    var label_buf: [64]u8 = undefined;

    var items_local_id: i32 = 0;

    var iter = try g.items.iterator(&u.scope.?);
    defer u.scope.?.reset();
    while (try iter.next()) |item| {
        if (u.current_category) |selected| {
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
        const add_btn_label = try std.fmt.bufPrintZ(&label_buf, "Add##{}", .{items_local_id});
        if (cimgui_dll.igButton(add_btn_label, .{})) {}
        if (item.base_capacity > 1) {
            cimgui_dll.igSameLine(0, -1.0);
            const add_max_btn_lbl = try std.fmt.bufPrintZ(&label_buf, "Add {}##{}", .{ item.base_capacity, items_local_id });
            if (cimgui_dll.igButton(add_max_btn_lbl, .{})) {}
        }
    }
}
