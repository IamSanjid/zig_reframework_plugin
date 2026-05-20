const std = @import("std");
const root = @import("root");

const re = @import("reframework");

const cimgui = @import("cimgui");
const cimgui_dll = @import("../cimgui_dll.zig");

const interop = re.interop;

const BehaviorTree = @import("../behavior_tree.zig").BehaviorTree;

const ui = @import("../ui.zig");
const u = ui.u;

const g = root.g;

const managed_types = @import("../managed_types.zig");
const EnemyRoleAction = managed_types.EnemyRoleAction;
const EnemySpawnParamDetails = managed_types.EnemySpawnParamDetails;

var current_position: ?@Vector(3, f32) = null;
var current_role_actions: std.ArrayList(EnemyRoleAction) = .empty;
var last_player_pos: ?@Vector(3, f32) = null;
var arena: std.heap.ArenaAllocator = undefined;

pub fn reset() void {
    arena = .init(u.arena.allocator());
    current_role_actions = .empty;
}

const f32_step: f32 = 5;
const f32_step_fast: f32 = 50;

fn inputVec3F(label: [:0]const u8, vec: *@Vector(3, f32)) void {
    cimgui_dll.igPushID_Str(label);
    defer cimgui_dll.igPopID();
    cimgui_dll.igText(label);
    _ = cimgui_dll.igInputScalar("X", cimgui.ImGuiDataType_Float, &vec[0], &f32_step, &f32_step_fast, "%f", 0);
    _ = cimgui_dll.igInputScalar("Y", cimgui.ImGuiDataType_Float, &vec[1], &f32_step, &f32_step_fast, "%f", 0);
    _ = cimgui_dll.igInputScalar("Z", cimgui.ImGuiDataType_Float, &vec[2], &f32_step, &f32_step_fast, "%f", 0);
}

fn spawnWithCurrentParams(enemy: EnemySpawnParamDetails) !void {
    const positon = current_position orelse return;
    return g.scene_enemy_management.queueSpawn(enemy, .{
        .position = positon,
        .role_actions = current_role_actions.items,
    });
}

pub fn draw() !void {
    cimgui_dll.igPushID_Str("##EnemySpawn");
    defer cimgui_dll.igPopID();
    cimgui_dll.igTextColored(ui.color_warning, "Experimental Enemy Spawner, use with caution.");
    const enemies = g.scene_enemy_management.enemies.items;

    if (!cimgui_dll.igBeginTable("##enemy_spawn_table", 3, cimgui.ImGuiTableFlags_Borders | cimgui.ImGuiTableFlags_Resizable, .{}, 0.0)) {
        return;
    }
    defer cimgui_dll.igEndTable();

    cimgui_dll.igTableSetupColumn("Spawner Name", cimgui.ImGuiTableColumnFlags_WidthStretch, 30.0, 0);
    cimgui_dll.igTableSetupColumn("Name", cimgui.ImGuiTableColumnFlags_WidthStretch, 30.0, 0);
    cimgui_dll.igTableSetupColumn("Action", cimgui.ImGuiTableColumnFlags_WidthStretch, 300.0, 0);

    cimgui_dll.igTableHeadersRow();

    for (enemies, 0..) |enemy, index| {
        const column_id = try std.fmt.bufPrintSentinel(&ui.label_buf, "enemy_spawn_column#{}", .{index}, 0);
        cimgui_dll.igPushID_Str(column_id);
        defer cimgui_dll.igPopID();

        cimgui_dll.igTableNextRow(0, 0.0);

        _ = cimgui_dll.igTableNextColumn();
        cimgui_dll.igText("%s", enemy.game_obj_name.ptr);

        _ = cimgui_dll.igTableNextColumn();
        cimgui_dll.igText("%s", enemy.enemy_type_name.ptr);

        _ = cimgui_dll.igTableNextColumn();
        if (cimgui_dll.igCollapsingHeader_BoolPtr("Spawn Params", null, 0)) {
            if (cimgui_dll.igButton("Spawn", .{})) {
                try spawnWithCurrentParams(enemy);
                return; // new-frame
            }
            if (cimgui_dll.igButton("Reset", .{})) {
                current_role_actions.clearRetainingCapacity();
                current_position = enemy.position;
                try current_role_actions.appendSlice(arena.allocator(), enemy.role_actions);
            }
            cimgui_dll.igSameLine(0, -1.0);
            if (cimgui_dll.igButton("Read Player Pos", .{})) {
                last_player_pos = try g.player.?.player_context.call(.get_Position, &u.scope, .fo(g.sdk), .{});
            }
            if (current_position == null) {
                current_position = enemy.position;
                try current_role_actions.appendSlice(arena.allocator(), enemy.role_actions);
            }
            if (current_role_actions.items.len < enemy.role_actions.len) {
                const old_len = current_role_actions.items.len;
                try current_role_actions.resize(arena.allocator(), enemy.role_actions.len);
                for (old_len..enemy.role_actions.len) |i| {
                    current_role_actions.items[i] = enemy.role_actions[i];
                }
            }
            if (last_player_pos) |pos| {
                var local_pos = pos;
                inputVec3F("Last Player Pos", &local_pos);
            }
            cimgui_dll.igSeparator();
            inputVec3F("Position", &current_position.?);
            cimgui_dll.igSeparatorText("Role Actions");
            for (0..enemy.role_actions.len) |action_idx| {
                const action = &current_role_actions.items[action_idx];
                const action_id = try std.fmt.bufPrintSentinel(&ui.label_buf, "enemy_spawn_action#{}", .{action.index}, 0);
                cimgui_dll.igPushID_Str(action_id);
                defer cimgui_dll.igPopID();
                cimgui_dll.igText("Index: %ld", action.index);
                cimgui_dll.igSeparator();
                inputVec3F("Resume Point", &action.resume_point);
                cimgui_dll.igSeparator();
                _ = cimgui_dll.igInputScalar("Resume Yaw", cimgui.ImGuiDataType_Float, &action.resume_yaw, &f32_step, &f32_step_fast, "%f", 0);
                cimgui_dll.igSeparator();
                inputVec3F("Return Point", &action.return_point);
                cimgui_dll.igSeparator();
                _ = cimgui_dll.igInputScalar("Return Yaw", cimgui.ImGuiDataType_Float, &action.return_yaw, &f32_step, &f32_step_fast, "%f", 0);
                cimgui_dll.igSeparator();
            }
        }
    }
}
