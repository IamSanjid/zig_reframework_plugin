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

pub var editable_btrees: std.ArrayList(BehaviorTreeData) = .empty;
pub var btree_addr_buf: [17:0]u8 = std.mem.zeroes([17:0]u8);
pub var btree_addr: usize = 0;
pub var btree_data: ?BehaviorTreeData = null;
var cached_arena: std.heap.ArenaAllocator = undefined;
var list_arena: std.heap.ArenaAllocator = undefined;

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

const BehaviorTreeData = struct {
    owner_name: [:0]const u8,
    action_types: []const [:0]const u8,
    root_tree: *BehaviorTree,
    self: *BehaviorTree,
};

pub fn reset() void {
    cached_arena = .init(u.arena.allocator());
    list_arena = .init(u.arena.allocator());

    btree_addr_buf = std.mem.zeroes([17:0]u8);
    btree_addr = 0;
    btree_data = null;
    editable_btrees = .empty;
}

fn getBTreeData(tree: *BehaviorTree, arena: std.mem.Allocator) !BehaviorTreeData {
    const component = tree.asComponent();
    const owner = component.getOwner();
    if (!owner.isManagedObject(.fo(g.sdk))) {
        return error.OwnerNotManagedObject;
    }
    const GameObjectT = try g.interop_cache.resolve("via.GameObject", g.tdb, .fo(g.sdk));

    const name_system_str = try GameObjectT.scoped(&u.scope).call(owner, "get_Name()", re.interop.SystemStringView, .fo(g.sdk), .{});
    const name = try std.unicode.utf16LeToUtf8AllocZ(arena, name_system_str.data);

    const handles = tree.getTrees();

    var action_types = std.ArrayList([:0]const u8).empty;
    defer action_types.deinit(arena);

    for (handles) |handle| {
        const tree_obj = handle.core.tree_object orelse continue;
        const actions = tree_obj.actions;
        for (actions.items[0..actions.len]) |action| {
            const action_type_def = action.getTypeDefinition(.fo(g.sdk)) orelse continue;
            const type_name = try action_type_def.getFullNameAlloc(.fo(g.sdk), arena);
            const type_name_z = try arena.dupeSentinel(u8, type_name, 0);
            try action_types.append(arena, type_name_z);
        }
    }

    var root_tree = tree;
    while (root_tree.prev) |prev| {
        if (prev == root_tree) {
            break;
        }
        root_tree = prev;
    }

    return .{
        .owner_name = name,
        .action_types = try action_types.toOwnedSlice(arena),
        .root_tree = root_tree,
        .self = tree,
    };
}

fn updateBTreeAddrBuf(tree: *BehaviorTree) !void {
    btree_addr_buf = std.mem.zeroes([17:0]u8);
    btree_addr = @intFromPtr(tree);
    _ = try std.fmt.bufPrint(&btree_addr_buf, "{x}", .{btree_addr});
}

fn isBT(ptr: *anyopaque) bool {
    @setRuntimeSafety(false);
    const mo = re.sdk.ManagedObject{ .raw = @ptrCast(@alignCast(ptr)) };
    if (!mo.isManagedObject(.fo(g.sdk))) {
        return false;
    }
    const BTreeT = g.interop_cache.resolve(BehaviorTree.full_type_name, g.tdb, .fo(g.sdk)) catch return false;
    const type_def = mo.getTypeDefinition(.fo(g.sdk)) orelse return false;
    return type_def.isDerivedFrom(.fo(g.sdk), BTreeT.type_def_metadata.def);
}

pub fn setEditableTreesFromFlow(component: *interop.ViaComponent) !void {
    clearEditableTrees();
    const BehaviorTreeT = try g.interop_cache.resolve(BehaviorTree.full_type_name, g.tdb, .fo(g.sdk));

    var child_component = component.childComponent();
    while (child_component) |child| : (child_component = child.childComponent()) {
        if (child == component) {
            break;
        }

        const child_mo = re.sdk.ManagedObject{ .raw = @ptrCast(@alignCast(child)) };
        if (!child_mo.isManagedObject(.fo(g.sdk))) {
            continue;
        }
        const child_type_def = child_mo.getTypeDefinition(.fo(g.sdk)) orelse continue;
        if (!child_type_def.isDerivedFrom(.fo(g.sdk), BehaviorTreeT.type_def_metadata.def)) {
            continue;
        }

        try addEditableTree(@ptrCast(@alignCast(child_mo.raw)));
    }

    if (editable_btrees.items.len > 0) {
        btree_data = try getBTreeDataAndUpdateAddr(editable_btrees.items[0].self);
    }
}

pub fn addEditableTree(tree: *BehaviorTree) !void {
    const arena = list_arena.allocator();
    return editable_btrees.append(arena, try getBTreeData(tree, arena));
}

pub fn clearEditableTrees() void {
    _ = list_arena.reset(.retain_capacity);
    editable_btrees = .empty;
}

pub fn getBTreeDataAndUpdateAddr(tree: *BehaviorTree) !BehaviorTreeData {
    _ = cached_arena.reset(.retain_capacity);
    const data = try getBTreeData(tree, cached_arena.allocator());
    try updateBTreeAddrBuf(tree);
    return data;
}

pub fn draw() !void {
    cimgui_dll.igPushID_Str("##EditBTree");
    defer cimgui_dll.igPopID();
    cimgui_dll.igTextColored(ui.color_warning, "Any of the *Native functions can cause crash because of out-of-date offsets.");

    if (editable_btrees.items.len > 0) {
        cimgui_dll.igText("Select one of the BTRee:");
    }
    for (editable_btrees.items) |btree| {
        const label = try std.fmt.bufPrintSentinel(&ui.label_buf, "{s}", .{btree.owner_name}, 0);
        if (cimgui_dll.igButton(label, .{})) {
            btree_data = try getBTreeDataAndUpdateAddr(btree.self);
            return;
        }
    }

    try hextTextInput("Behavior Tree Addr", &btree_addr_buf, &btree_addr);

    if (btree_data) |data| {
        if (btree_addr != @intFromPtr(data.self)) {
            btree_data = null;
            return;
        }
        cimgui_dll.igText("Name: %s", data.owner_name.ptr);

        const tree = data.self;
        if (cimgui_dll.igButton("<<", .{})) {
            if (tree.prev) |prev| {
                btree_data = try getBTreeDataAndUpdateAddr(prev);
            }
            return;
        }
        cimgui_dll.igSameLine(0, -1);
        if (cimgui_dll.igButton(">>", .{})) {
            if (tree.next) |next| {
                btree_data = try getBTreeDataAndUpdateAddr(next);
            }
            return;
        }

        if (cimgui_dll.igButton("Start", .{})) {
            try g.btree_management.queueAction(.{ .start = tree });
            return;
        }
        if (cimgui_dll.igIsItemHovered(0)) {
            cimgui_dll.igSetTooltip("Might cause crash, forcefully calls the action start function.");
        }
        cimgui_dll.igSameLine(0, -1);
        if (cimgui_dll.igButton("StartNative", .{})) {
            try g.btree_management.queueAction(.{ .start_native = tree });
            return;
        }
        if (cimgui_dll.igIsItemHovered(0)) {
            cimgui_dll.igSetTooltip("Uses the native function to start, might need an update for the plugin for updated vtable/function pointer offset" ++
                "\nMight cause crash, forcefully calls the action start function.");
        }
        cimgui_dll.igSameLine(0, -1);
        if (cimgui_dll.igButton("Remove Native", .{})) {
            try g.btree_management.queueAction(.{ .remove_native = tree });
            if (tree.next) |next| {
                btree_data = try getBTreeDataAndUpdateAddr(next);
            } else if (tree.prev) |prev| {
                btree_data = try getBTreeDataAndUpdateAddr(prev);
            } else {
                btree_data = null;
            }
            return;
        }
        if (cimgui_dll.igIsItemHovered(0)) {
            cimgui_dll.igSetTooltip("Removes the tree from the execution queue in the next frame.");
        }
        cimgui_dll.igSameLine(0, -1);
        if (cimgui_dll.igButton("Edit Root", .{})) {
            btree_data = try getBTreeDataAndUpdateAddr(data.root_tree);
            return;
        }

        cimgui_dll.igText("Actions:");

        for (data.action_types, 0..) |action, i| {
            cimgui_dll.igText("[%d] %s", i, action.ptr);
        }
    } else {
        if (btree_addr == 0 or !isBT(@ptrFromInt(btree_addr))) {
            btree_addr = 0;
            cimgui_dll.igText("Not Valid Behavior Tree");
            return;
        }
        btree_data = try getBTreeDataAndUpdateAddr(@ptrFromInt(btree_addr));
    }
}
