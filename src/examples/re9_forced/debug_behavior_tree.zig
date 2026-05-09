const std = @import("std");
const root = @import("root");

const re = @import("reframework");

const cimgui = @import("cimgui");
const cimgui_dll = @import("cimgui_dll.zig");

const behavior_tree = @import("behavior_tree.zig");

const g = root.g;

var tree_addr_buf: [17:0]u8 = undefined;
var tree_mo: ?re.sdk.ManagedObject = null;
var behaviour_tree_type_def: ?re.sdk.TypeDefinition = null;
var heap_arena: ?std.heap.ArenaAllocator = null;

const StringBuilder = struct {
    builder: std.ArrayList(u8) = .empty,
    arena: std.mem.Allocator,

    pub fn print(self: *StringBuilder, comptime fmt: []const u8, args: anytype) !void {
        return self.builder.print(self.arena, fmt, args);
    }

    pub fn println(self: *StringBuilder, comptime fmt: []const u8, args: anytype) !void {
        try self.print(fmt ++ "\n", args);
    }

    pub fn toCString(self: *StringBuilder) ![:0]u8 {
        return self.builder.toOwnedSliceSentinel(self.arena, 0);
    }
};

pub fn draw() !void {
    if (behaviour_tree_type_def == null) {
        behaviour_tree_type_def = g.tdb.findType(.fo(g.sdk), "via.behaviortree.BehaviorTree") orelse return;
    }

    if (heap_arena == null) {
        heap_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }

    const arena = heap_arena.?.allocator();
    defer _ = heap_arena.?.reset(.retain_capacity);

    cimgui_dll.igSetNextItemOpen(false, cimgui.ImGuiCond_FirstUseEver);
    if (!cimgui_dll.igCollapsingHeader_BoolPtr("RE9 Behaviour Tree Debug", null, 0)) {
        return;
    }

    if (cimgui_dll.igInputText("Behaviour Tree Addr", &tree_addr_buf, tree_addr_buf.len, cimgui.ImGuiInputTextFlags_CharsHexadecimal, null, null)) {
        if (tree_addr_buf[0] != 0) {
            errdefer tree_addr_buf = std.mem.zeroes([17:0]u8);

            const addr_str: []u8 = std.mem.sliceTo(&tree_addr_buf, 0);
            const addr = try std.fmt.parseInt(usize, addr_str, 16);
            tree_mo = .{ .raw = @ptrFromInt(addr) };
        } else {
            tree_mo = null;
        }
    }

    if (tree_mo) |mo| {
        if (!mo.isManagedObject(.fo(g.sdk))) {
            cimgui_dll.igText("Not a valid ManagedObject");
            return;
        }

        const type_def = mo.getTypeDefinition(.fo(g.sdk)) orelse {
            cimgui_dll.igText("Failed to get TypeDefinition");
            return;
        };

        if (!type_def.isDerivedFrom(.fo(g.sdk), behaviour_tree_type_def.?)) {
            cimgui_dll.igText("Not a BehaviourTree");
            return;
        }

        var builder = StringBuilder{
            .arena = arena,
        };

        const tree: *behavior_tree.BehaviorTree = @ptrCast(mo.raw);
        const handles = tree.getTrees();

        try builder.println("Tree-Handles: {}\n", .{handles.len});
        for (handles, 0..) |handle, i| {
            try builder.println("Handle {}: {*}", .{ i, handle });
            const tree_obj = handle.core.tree_object;
            try builder.println("  TreeObj {*}", .{tree_obj});
        }

        const tree_str = try builder.toCString();
        cimgui_dll.igText(tree_str.ptr);

        if (cimgui_dll.igIsMouseReleased_Nil(cimgui.ImGuiKey_MouseRight)) {
            cimgui_dll.igSetClipboardText(tree_str.ptr);
        }
    }
}
