const std = @import("std");
const root = @import("root");

const re = @import("reframework");

const cimgui = @import("cimgui");
const cimgui_dll = @import("../cimgui_dll.zig");

const managed_types = @import("../managed_types.zig");

const behaviortree_edits = @import("behaviortree_edits.zig");

const interop = re.interop;

const ui = @import("../ui.zig");
const u = ui.u;

const g = root.g;

pub var flow_progressive_number: i32 = 0;
pub var owner_name_search_buf: [512:0]u8 = undefined;
pub var action_type_search_buf: [512:0]u8 = undefined;
pub var owner_name_search: ?[]const u8 = null;
pub var action_type_search: ?[]const u8 = null;
pub var read_flow_progressive_number: ?i32 = null;
pub var filter_name_hash: u32 = 0;
pub var filter_name_hash_count: i32 = 0;

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

        if (filter_name_hash != 0 and flow_obj.name_hash != filter_name_hash) {
            continue;
        }

        if (owner_name_search) |search| {
            if (std.ascii.findIgnoreCase(flow_data.owner_name, search) == null) {
                continue;
            }
        }
        if (action_type_search) |search| {
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
            const copy_text = try std.fmt.bufPrintSentinel(&ui.label_buf, "0x{x}", .{@intFromPtr(component.managed.raw)}, 0);
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
                &ui.label_buf,
                "Edit##0x{x}-{}",
                .{ @intFromPtr(component.managed.raw), i },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                try behaviortree_edits.setEditableTreesFromFlow(@ptrCast(component.managed.raw));
                u.focus_btree_edits = true;
                return;
            }
        }

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &ui.label_buf,
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
                &ui.label_buf,
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

        if (filter_name_hash != 0) continue;

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &ui.label_buf,
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
                &ui.label_buf,
                "Set##0x{x}-{}",
                .{ @intFromPtr(flow_obj.component.managed.raw), i },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                try g.level_flow_manager.call(
                    .requestChangeProgressiveNumber,
                    &u.scope,
                    .fo(g.sdk),
                    .{ flow_obj.name_hash, flow_progressive_number },
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
                &ui.label_buf,
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
                &ui.label_buf,
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
                &ui.label_buf,
                "Read##0x{x}-{}",
                .{ @intFromPtr(component.managed.raw), i },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                read_flow_progressive_number = try g.level_flow_manager.call(
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

pub fn draw() !void {
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

        if (filter_name_hash == 0) {
            cimgui_dll.igPushStyleColor_U32(cimgui.ImGuiCol_Button, ui.color_active);
            cimgui_dll.igPushStyleColor_U32(cimgui.ImGuiCol_ButtonHovered, ui.color_active);
            _ = cimgui_dll.igButton("All", .{});
            cimgui_dll.igPopStyleColor(2);
        } else {
            if (cimgui_dll.igButton("All", .{})) {
                filter_name_hash = 0;
            }
        }
        cimgui_dll.igSameLine(0, -1.0);

        var same_line_remaining: u32 = 5;

        var name_hashes = g.level_flow_managed_objects.name_hashes.iterator();
        var reset_filter_name_hash = filter_name_hash != 0;
        while (name_hashes.next()) |entry| {
            const name_hash = entry.key_ptr.*;
            const name_count = entry.value_ptr.*;

            var active = false;
            if (filter_name_hash != 0 and filter_name_hash == name_hash) {
                cimgui_dll.igPushStyleColor_U32(cimgui.ImGuiCol_Button, ui.color_active);
                cimgui_dll.igPushStyleColor_U32(cimgui.ImGuiCol_ButtonHovered, ui.color_active);
                active = true;
                reset_filter_name_hash = false;
            }

            const btn_label = try std.fmt.bufPrintSentinel(&ui.label_buf, "{}", .{name_hash}, 0);
            if (cimgui_dll.igButton(btn_label, .{})) {
                if (filter_name_hash == name_hash) {
                    filter_name_hash = 0;
                } else {
                    filter_name_hash = name_hash;
                    filter_name_hash_count = name_count;
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
            filter_name_hash = 0;
            filter_name_hash_count = 0;
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
            &owner_name_search_buf,
            owner_name_search_buf.len,
            cimgui.ImGuiInputTextFlags_AutoSelectAll,
            input_width,
        )) {
            if (owner_name_search_buf[0] != 0) {
                owner_name_search = std.mem.sliceTo(owner_name_search_buf[0..], 0);
            } else {
                owner_name_search = null;
            }
        }

        cimgui_dll.igSameLine(0.0, -1.0);

        if (leftLabelInputText(
            "Action Search",
            "##action_type_search",
            &action_type_search_buf,
            action_type_search_buf.len,
            cimgui.ImGuiInputTextFlags_AutoSelectAll,
            input_width,
        )) {
            if (action_type_search_buf[0] != 0) {
                action_type_search = std.mem.sliceTo(action_type_search_buf[0..], 0);
            } else {
                action_type_search = null;
            }
        }
    }

    const level_flows = g.level_flow_managed_objects.collection.items;
    if (filter_name_hash != 0) {
        cimgui_dll.igText("Total flows: %d", filter_name_hash_count);
        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &ui.label_buf,
                "Next##0x{x}-{}",
                .{ filter_name_hash, filter_name_hash_count },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                _ = try g.level_flow_manager.call(.sendNext, &u.scope, .fo(g.sdk), .{ filter_name_hash, null });
                return;
            }
            if (cimgui_dll.igIsItemHovered(0)) {
                cimgui_dll.igSetTooltip("Requests the next step for the level flow, different name hash means different level flow, press it multiple times to progress in-game.");
            }
        }

        cimgui_dll.igSameLine(0.0, -1.0);

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &ui.label_buf,
                "Set##0x{x}-{}",
                .{ filter_name_hash, filter_name_hash_count },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                try g.level_flow_manager.call(
                    .requestChangeProgressiveNumber,
                    &u.scope,
                    .fo(g.sdk),
                    .{ filter_name_hash, flow_progressive_number },
                );
                return;
            }
            if (cimgui_dll.igIsItemHovered(0)) {
                cimgui_dll.igSetTooltip("Sets the progressive number equal to the input value in the Config section.\n" ++
                    "Can be used to skip or repeat certain sections if the flow supports it.\n" ++
                    "Usually you stop the flow and then set the progressive number again and again.");
            }
        }

        cimgui_dll.igSameLine(0.0, -1.0);

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &ui.label_buf,
                "Reset##0x{x}-{}",
                .{ filter_name_hash, filter_name_hash_count },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                try g.level_flow_manager.call(.requestResetProgressiveNumber, &u.scope, .fo(g.sdk), .{filter_name_hash});
                return;
            }
        }

        cimgui_dll.igSameLine(0.0, -1.0);

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &ui.label_buf,
                "Stop##0x{x}-{}",
                .{ filter_name_hash, filter_name_hash_count },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                try g.level_flow_manager.call(.requestStopProgressive, &u.scope, .fo(g.sdk), .{filter_name_hash});
                return;
            }
        }

        cimgui_dll.igSameLine(0.0, -1.0);

        {
            const btn_label = try std.fmt.bufPrintSentinel(
                &ui.label_buf,
                "Read##0x{x}-{}",
                .{ filter_name_hash, filter_name_hash_count },
                0,
            );
            if (cimgui_dll.igButton(btn_label, .{})) {
                read_flow_progressive_number = try g.level_flow_manager.call(
                    .getProgressiveNumber,
                    &u.scope,
                    .fo(g.sdk),
                    .{filter_name_hash},
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

    if (read_flow_progressive_number) |number| {
        cimgui_dll.igText("Progressive Number: %d", number);
        cimgui_dll.igSameLine(0, -1.0);
        if (cimgui_dll.igButton("Clear##level_prog_number_clear", .{})) {
            read_flow_progressive_number = null;
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

    if (filter_name_hash != 0 or action_type_search != null or owner_name_search != null) {
        // TODO: cache filtered results and then only draw those...
        try drawLevelFlowsRange(level_flows, 0, level_flows.len);
        return;
    }

    // Why clipper? Goal is to be below 1ms re-framework frame time.
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
