const std = @import("std");
const root = @import("root");

const re = @import("reframework");

const cimgui = @import("cimgui");
const cimgui_dll = @import("cimgui_dll.zig");

const behavior_tree = @import("behavior_tree.zig");

const g = root.g;

var tree_addr_buf: [17:0]u8 = undefined;
var tree_mo: ?re.sdk.ManagedObject = null;

var tree_obj_from_actions_addr_buf: [17:0]u8 = undefined;
var tree_obj_from_actions_addr: usize = 0;

var core_handle_from_tree_obj_addr_buf: [17:0]u8 = undefined;
var core_handle_from_tree_obj_addr: usize = 0;

var behaviour_tree_type_def: ?re.sdk.TypeDefinition = null;
var corehandle_type_def: ?re.sdk.TypeDefinition = null;

var heap_arena: ?std.heap.ArenaAllocator = null;

const StringBuilder = struct {
    builder: std.ArrayList(u8) = .empty,
    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator) StringBuilder {
        return .{ .arena = arena };
    }

    pub fn one(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
        var builder = StringBuilder.init(arena);
        try builder.println(fmt, args);
        return try builder.toCString();
    }

    pub fn print(self: *StringBuilder, comptime fmt: []const u8, args: anytype) !void {
        return self.builder.print(self.arena, fmt, args);
    }

    pub fn println(self: *StringBuilder, comptime fmt: []const u8, args: anytype) !void {
        try self.print(fmt ++ "\n", args);
    }

    pub fn indentedPrintln(self: *StringBuilder, indent: u32, comptime fmt: []const u8, args: anytype) !void {
        for (0..indent) |_| {
            try self.print("  ", .{});
        }
        try self.println(fmt, args);
    }

    pub fn toCString(self: *StringBuilder) ![:0]u8 {
        return self.builder.toOwnedSliceSentinel(self.arena, 0);
    }
};

inline fn hextTextInput(label: [*c]const u8, buf: *[17:0]u8, out: anytype) !void {
    if (cimgui_dll.igInputText(label, &buf.*, buf.len, cimgui.ImGuiInputTextFlags_CharsHexadecimal, null, null)) {
        const T = @TypeOf(out);

        if (buf[0] == 0) {
            switch (T) {
                *?re.sdk.ManagedObject => out.* = null,
                *usize => out.* = 0,
                else => @compileError("Not supported type: " ++ @typeName(T)),
            }
            return;
        }
        errdefer buf.* = std.mem.zeroes([17:0]u8);
        const addr_str: []u8 = std.mem.sliceTo(buf, 0);
        const addr = try std.fmt.parseInt(usize, addr_str, 16);

        switch (T) {
            *?re.sdk.ManagedObject => {
                out.* = .{ .raw = @ptrFromInt(addr) };
            },
            *usize => {
                out.* = addr;
            },
            else => @compileError("Not supported type: " ++ @typeName(T)),
        }
    }
}

fn showTextAndLetCopy(text: [*c]const u8) void {
    cimgui_dll.igText(text);
    if (cimgui_dll.igIsItemHovered(0) and cimgui_dll.igIsMouseReleased_Nil(cimgui.ImGuiMouseButton_Right)) {
        cimgui_dll.igSetClipboardText(text);
    }
}

fn isBT(ptr: *anyopaque) bool {
    @setRuntimeSafety(false);
    const mo = re.sdk.ManagedObject{ .raw = @ptrCast(@alignCast(ptr)) };
    if (!mo.isManagedObject(.fo(g.sdk))) {
        return false;
    }
    const type_def = mo.getTypeDefinition(.fo(g.sdk)) orelse return false;
    return type_def.isDerivedFrom(.fo(g.sdk), behaviour_tree_type_def.?);
}

var owner_cache: ?struct {
    obj: re.sdk.ManagedObject,
    name: []const u8,
} = null;

fn getOwnerName(tree: *behavior_tree.BehaviorTree) ![]const u8 {
    const component = tree.asComponent();
    const owner = component.getOwner();
    if (owner_cache) |cache| {
        if (cache.obj.raw == owner.raw) {
            return cache.name;
        }
    }
    if (!owner.isManagedObject(.fo(g.sdk))) {
        return error.OwnerNotManagedObject;
    }
    const GameObjectT = try g.interop_cache.resolve("via.GameObject", g.tdb, .fo(g.sdk));
    var scope = g.interop_cache.newScope(g.allocator);
    defer scope.deinit();

    const name_system_str = try GameObjectT.scoped(&scope).call(owner, "get_Name()", re.interop.SystemStringView, .fo(g.sdk), .{});
    const name = try std.unicode.utf16LeToUtf8Alloc(g.allocator, name_system_str.data);

    if (owner_cache) |*cache| {
        g.allocator.free(cache.name);
        cache.obj = owner;
        cache.name = name;
    } else {
        owner_cache = .{ .obj = owner, .name = name };
    }
    return name;
}

pub fn draw() !void {
    if (behaviour_tree_type_def == null) {
        behaviour_tree_type_def = g.tdb.findType(.fo(g.sdk), "via.behaviortree.BehaviorTree") orelse return;
    }
    if (corehandle_type_def == null) {
        corehandle_type_def = g.tdb.findType(.fo(g.sdk), "via.behaviortree.BehaviorTree.CoreHandle") orelse return;
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

    try hextTextInput("Behaviour Tree Addr", &tree_addr_buf, &tree_mo);
    if (tree_mo) |mo| {
        cimgui_dll.igText("Behavior Tree:");

        if (!isBT(@ptrCast(mo.raw))) {
            cimgui_dll.igText("Not a BehaviourTree");
            return;
        }

        var builder = StringBuilder{
            .arena = arena,
        };

        const tree: *behavior_tree.BehaviorTree = .fo(mo.raw);

        if (cimgui_dll.igButton("<<##Btree", .{})) {
            if (tree.prev) |prev| {
                tree_mo = .{ .raw = @ptrCast(prev) };
            }
            return;
        }
        cimgui_dll.igSameLine(0, -1);
        if (cimgui_dll.igButton(">>##BTree", .{})) {
            if (tree.next) |next| {
                tree_mo = .{ .raw = @ptrCast(next) };
            }
            return;
        }

        var root_tree = tree;
        var pos: u32 = 0;
        while (root_tree.prev) |prev| {
            if (prev == root_tree) {
                break;
            }
            pos += 1;
            root_tree = prev;
        }

        if (cimgui_dll.igButton("Start##BTree", .{})) {
            try g.btree_management.queueAction(.{ .start = tree });
            if (tree.next) |next| {
                tree_mo = .{ .raw = @ptrCast(next) };
            } else {
                tree_mo = null;
            }
            return;
        }
        cimgui_dll.igSameLine(0, -1);
        if (cimgui_dll.igButton("Remove##BTree", .{})) {
            tree.removeFromExecutionQueue();
            if (tree.next) |next| {
                tree_mo = .{ .raw = @ptrCast(next) };
            } else if (tree.prev) |prev| {
                tree_mo = .{ .raw = @ptrCast(prev) };
            } else {
                tree_mo = null;
            }
            return;
        }

        if (getOwnerName(tree)) |owner_name| {
            try builder.println("Name: {s}", .{owner_name});
        } else |_| {}
        try builder.println("Root Tree: {*}", .{root_tree});
        try builder.println("Next after Root Tree: {*}", .{root_tree.next});
        try builder.println("Prev Tree: {*}", .{tree.prev});
        try builder.println("[{}]Current Tree: {*}", .{ pos, tree });
        try builder.println("Next Tree: {*}", .{tree.next});
        try builder.println("CanExecute: {}", .{tree.can_execute});

        const handles = tree.getTrees();

        try builder.println("Tree-Handles: {}", .{handles.len});
        for (handles, 0..) |handle, i| {
            try builder.println("Handle {}: {*}", .{ i, handle });

            try builder.indentedPrintln(1, "Core {*}", .{&handle.core});

            try builder.indentedPrintln(1, "SelectorArg {*}", .{handle.core.selector_arg.raw});
            try builder.indentedPrintln(1, "ActionArg {*}", .{handle.core.action_arg});
            try builder.indentedPrintln(1, "ConditionArg {*}", .{handle.core.condition_arg.raw});
            try builder.indentedPrintln(1, "SelectorConditionArg {*}", .{handle.core.selector_condition_arg.raw});
            try builder.indentedPrintln(1, "SelectorCallerArg {*}", .{handle.core.selector_caller_arg.raw});
            try builder.indentedPrintln(1, "TransitionEventArg {*}", .{handle.core.transition_event_arg.raw});
            try builder.indentedPrintln(1, "UserVariablesHub {*}", .{handle.core.user_variables_hub.raw});
            try builder.indentedPrintln(1, "MaybeNextComponent {*}", .{handle.core.maybe_next_component});

            const tree_obj = handle.core.tree_object orelse {
                try builder.indentedPrintln(1, "No TreeObject", .{});
                continue;
            };
            try builder.indentedPrintln(1, "TreeObj {*}", .{tree_obj});
            if (tree_obj.data) |data| {
                try builder.indentedPrintln(2, "Data {*}", .{data});
                try builder.indentedPrintln(3, "SomeCount: {}", .{data.some_count});
            } else {
                try builder.indentedPrintln(2, "No Data", .{});
            }
            const actions = tree_obj.actions;
            for (actions.items[0..actions.len], 0..) |action, j| {
                const action_type_def = action.getTypeDefinition(.fo(g.sdk)) orelse continue;
                const type_name = try action_type_def.getFullNameAlloc(.fo(g.sdk), g.allocator);
                defer g.allocator.free(type_name);
                try builder.indentedPrintln(2, "Action {}: {*} = {s}", .{ j, action.raw, type_name });
            }
            try builder.indentedPrintln(2, "-=-END OF ACTIONS-=-", .{});
            // try builder.indentedPrintln(2, "Nodes:", .{});
            // for (tree_obj.nodes.items[0..tree_obj.nodes.len], 0..) |node, j| {
            //     try builder.indentedPrintln(3, "Node {}: {*}", .{ j, node });
            // }
        }

        const tree_str = try builder.toCString();
        cimgui_dll.igText(tree_str.ptr);

        if (cimgui_dll.igIsItemHovered(0) and cimgui_dll.igIsMouseReleased_Nil(cimgui.ImGuiMouseButton_Right)) {
            std.log.debug("Released Right Mouse", .{});
            cimgui_dll.igSetClipboardText(tree_str.ptr);
        }
    }

    try hextTextInput("Reverse TreeObj from Actions", &tree_obj_from_actions_addr_buf, &tree_obj_from_actions_addr);
    if (tree_obj_from_actions_addr != 0) {
        const tree_obj: *behavior_tree.TreeObject = @ptrFromInt(
            tree_obj_from_actions_addr -
                @offsetOf(behavior_tree.TreeObject, "actions"),
        );
        showTextAndLetCopy(try StringBuilder.one(arena, "TreeObj from Actions: {*}", .{tree_obj}));
    }

    try hextTextInput("Reverse CoreHandle from TreeObj", &core_handle_from_tree_obj_addr_buf, &core_handle_from_tree_obj_addr);
    if (core_handle_from_tree_obj_addr != 0) {
        cimgui_dll.igText("CoreHandle Reverse:");
        const core_handle: *behavior_tree.CoreHandle = @ptrFromInt(
            core_handle_from_tree_obj_addr -
                @offsetOf(behavior_tree.Core, "tree_object") -
                @offsetOf(behavior_tree.CoreHandle, "core"),
        );
        const core_handle_mo = re.sdk.ManagedObject{ .raw = @ptrCast(core_handle) };
        if (!core_handle_mo.isManagedObject(.fo(g.sdk))) {
            cimgui_dll.igText("Not a valid ManagedObject");
            return;
        }
        const type_def = core_handle_mo.getTypeDefinition(.fo(g.sdk)) orelse {
            cimgui_dll.igText("Failed to get TypeDef");
            return;
        };
        if (!type_def.isDerivedFrom(.fo(g.sdk), corehandle_type_def.?)) {
            cimgui_dll.igText("Not a CoreHandle");
            return;
        }

        showTextAndLetCopy(try StringBuilder.one(arena, "CoreHandle from TreeObj: {*}", .{core_handle}));
    }
}
