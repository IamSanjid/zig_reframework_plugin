const std = @import("std");
const re = @import("reframework");

const interop = re.interop;

pub const NodeArray = extern struct {
    items: [*]*const TreeNode,
    len: u32,
};

pub const ManagedArray = extern struct {
    items: [*]*const TreeNode,
    len: u32,
    capacity: u32,
};

pub const BehaviorTree = opaque {
    const trees_offset = re.sdk.ManagedObject.runtime_size + 0x20;
    const trees_count_offset = trees_offset + @sizeOf(*[*]*BehaviorTreeCoreHandle);

    const Self = @This();

    pub fn getTrees(self: *const Self) []*BehaviorTreeCoreHandle {
        const ptr = @intFromPtr(self);
        const trees_count_ptr: *u32 = @ptrFromInt(ptr + trees_count_offset);
        const trees_ptr_ptr: *[*]*BehaviorTreeCoreHandle = @ptrFromInt(ptr + trees_offset);
        const trees_ptr = trees_ptr_ptr.*;
        return trees_ptr[0..trees_count_ptr.*];
    }
};

pub const BehaviorTreeCoreHandle = extern struct {
    _obj_padding: [re.sdk.ManagedObject.runtime_size]u8 align(@alignOf(*anyopaque)),
    _padding1: ?*anyopaque,
    core: Core,
};

pub const Core = extern struct {
    vtable: **const anyopaque,
    tree_object: *const TreeObject,
};

pub const TreeObject = extern struct {
    data: ?*anyopaque,
    nodes: NodeArray,
};

pub const TreeNode = opaque {};
