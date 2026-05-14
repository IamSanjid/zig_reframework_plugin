//! These struct layouts are only tested on RE9. They are not guaranteed to be correct for other versions of the game.
//!
//! As of May 11, 2026, before Leon Must Die mode update, the game seems to be polling a queue of BehaviorTree objects for execution.
//! Probably multiple threads are polling the queue concurrently. And there seems to be some sort of btree group type, where each group has its own queue.
//! Multiple threads are polling specific group of queues concurrently.
//!
//! Tips to find this place, set breakpoint any of the `start(via.behaviortree.ActionArg)` managed il2cpp function, and follow the stack trace, you should see something similar.
//!
//! The structure should be same for every other game with the same TDB version of RE9.
//!
//! This is the place where the behavior tree queue is polled for execution.
//! RCX = BehaviorTree*
//! re9.exe+4D16118 - 48 8B 03              - mov rax,[rbx]
//! re9.exe+4D1611B - 48 89 D9              - mov rcx,rbx
//! re9.exe+4D1611E - 48 89 FA              - mov rdx,rdi
//! re9.exe+4D16121 - FF 90 88000000        - call qword ptr [rax+00000088]
//!
//! The probe if you want to attempt to do an aob scan, try to wild card the relative addresses:
//!
//! re9.exe+4D16060 - 41 56                 - push r14
//! re9.exe+4D16062 - 56                    - push rsi
//! re9.exe+4D16063 - 57                    - push rdi
//! re9.exe+4D16064 - 55                    - push rbp
//! re9.exe+4D16065 - 53                    - push rbx
//! re9.exe+4D16066 - 48 83 EC 30           - sub rsp,30
//! re9.exe+4D1606A - 48 89 CE              - mov rsi,rcx
//! re9.exe+4D1606D - 48 8B 05 CC5DA509     - mov rax,[re9.exe+E76BE40]
//! re9.exe+4D16074 - 48 31 E0              - xor rax,rsp
//! re9.exe+4D16077 - 48 89 44 24 28        - mov [rsp+28],rax
//! re9.exe+4D1607C - 48 8B 0D BDB1AF09     - mov rcx,[re9.exe+E811240]
//! re9.exe+4D16083 - BA FFFFFFFF           - mov edx,FFFFFFFF
//! re9.exe+4D16088 - E8 83B06000           - call re9.exe+5321110
//! re9.exe+4D1608D - 48 89 C7              - mov rdi,rax
//! re9.exe+4D16090 - 48 89 44 24 20        - mov [rsp+20],rax
//! re9.exe+4D16095 - 8B 40 78              - mov eax,[rax+78]
//! re9.exe+4D16098 - 85 C0                 - test eax,eax
//! re9.exe+4D1609A - 75 0B                 - jne re9.exe+4D160A7
//! re9.exe+4D1609C - 48 89 F9              - mov rcx,rdi
//! re9.exe+4D1609F - E8 0CB06000           - call re9.exe+53210B0
//! re9.exe+4D160A4 - 8B 47 78              - mov eax,[rdi+78]
//! re9.exe+4D160A7 - FF C0                 - inc eax
//! re9.exe+4D160A9 - 89 47 78              - mov [rdi+78],eax
//! re9.exe+4D160AC - 80 7E 18 00           - cmp byte ptr [rsi+18],00
//! re9.exe+4D160B0 - 75 77                 - jne re9.exe+4D16129
//! re9.exe+4D160B2 - 48 8B 9E 40040000     - mov rbx,[rsi+00000440]
//! re9.exe+4D160B9 - 48 85 DB              - test rbx,rbx
//! re9.exe+4D160BC - 0F84 E8000000         - je re9.exe+4D161AA
//! re9.exe+4D160C2 - 48 8D 7C 24 20        - lea rdi,[rsp+20]
//! re9.exe+4D160C7 - 48 8B 8B C0000000     - mov rcx,[rbx+000000C0]
//! re9.exe+4D160CE - 48 89 D8              - mov rax,rbx
//! re9.exe+4D160D1 - F0 48 0FB1 8E 40040000  - lock cmpxchg [rsi+00000440],rcx
//! re9.exe+4D160DA - 74 11                 - je re9.exe+4D160ED
//! re9.exe+4D160DC - 48 8B 9E 40040000     - mov rbx,[rsi+00000440]
//! re9.exe+4D160E3 - 48 85 DB              - test rbx,rbx
//! re9.exe+4D160E6 - 75 DF                 - jne re9.exe+4D160C7
//! re9.exe+4D160E8 - E9 BD000000           - jmp re9.exe+4D161AA
//! re9.exe+4D160ED - 80 BB AC000000 00     - cmp byte ptr [rbx+000000AC],00
//! re9.exe+4D160F4 - 74 10                 - je re9.exe+4D16106
//! re9.exe+4D160F6 - 48 8B 03              - mov rax,[rbx]
//! re9.exe+4D160F9 - 48 89 D9              - mov rcx,rbx
//! re9.exe+4D160FC - FF 90 A0000000        - call qword ptr [rax+000000A0]
//! re9.exe+4D16102 - 84 C0                 - test al,al
//! re9.exe+4D16104 - 74 D6                 - je re9.exe+4D160DC
//! re9.exe+4D16106 - 80 7E 08 00           - cmp byte ptr [rsi+08],00
//! re9.exe+4D1610A - 75 0C                 - jne re9.exe+4D16118
//! re9.exe+4D1610C - 48 8B 03              - mov rax,[rbx]
//! re9.exe+4D1610F - 48 89 D9              - mov rcx,rbx
//! re9.exe+4D16112 - FF 90 98000000        - call qword ptr [rax+00000098]
//! re9.exe+4D16118 - 48 8B 03              - mov rax,[rbx]
//! re9.exe+4D1611B - 48 89 D9              - mov rcx,rbx
//! re9.exe+4D1611E - 48 89 FA              - mov rdx,rdi
//! re9.exe+4D16121 - FF 90 88000000        - call qword ptr [rax+00000088]
//! re9.exe+4D16127 - EB B3                 - jmp re9.exe+4D160DC
//! re9.exe+4D16129 - 48 8B 8E 48040000     - mov rcx,[rsi+00000448]
//! re9.exe+4D16130 - 48 85 C9              - test rcx,rcx
//! re9.exe+4D16133 - 74 75                 - je re9.exe+4D161AA
//! re9.exe+4D16135 - 48 8D 7C 24 20        - lea rdi,[rsp+20]
//! re9.exe+4D1613A - 48 8B 51 10           - mov rdx,[rcx+10]
//! re9.exe+4D1613E - 48 89 C8              - mov rax,rcx
//! re9.exe+4D16141 - F0 48 0FB1 96 48040000  - lock cmpxchg [rsi+00000448],rdx
//! re9.exe+4D1614A - 75 52                 - jne re9.exe+4D1619E
//! re9.exe+4D1614C - 48 8B 19              - mov rbx,[rcx]
//! re9.exe+4D1614F - 48 85 DB              - test rbx,rbx
//! re9.exe+4D16152 - 74 4A                 - je re9.exe+4D1619E
//! re9.exe+4D16154 - E8 D7726000           - call re9.exe+531D430
//! re9.exe+4D16159 - 49 89 C6              - mov r14,rax
//! re9.exe+4D1615C - 80 7E 08 00           - cmp byte ptr [rsi+08],00
//! re9.exe+4D16160 - 75 0C                 - jne re9.exe+4D1616E
//! re9.exe+4D16162 - 48 8B 03              - mov rax,[rbx]
//! re9.exe+4D16165 - 48 89 D9              - mov rcx,rbx
//! re9.exe+4D16168 - FF 90 98000000        - call qword ptr [rax+00000098]
//! re9.exe+4D1616E - 48 8B 03              - mov rax,[rbx]
//! re9.exe+4D16171 - 48 89 D9              - mov rcx,rbx
//! re9.exe+4D16174 - 48 89 FA              - mov rdx,rdi
//! re9.exe+4D16177 - FF 90 88000000        - call qword ptr [rax+00000088]
//! re9.exe+4D1617D - 8B AB B0000000        - mov ebp,[rbx+000000B0]
//! re9.exe+4D16183 - E8 A8726000           - call re9.exe+531D430
//! re9.exe+4D16188 - 44 29 F0              - sub eax,r14d
//! re9.exe+4D1618B - 01 E8                 - add eax,ebp
//! re9.exe+4D1618D - D1 E8                 - shr eax,1
//! re9.exe+4D1618F - 89 83 B0000000        - mov [rbx+000000B0],eax
//! re9.exe+4D16195 - 48 8B 9B C0000000     - mov rbx,[rbx+000000C0]
//! re9.exe+4D1619C - EB B1                 - jmp re9.exe+4D1614F
//! re9.exe+4D1619E - 48 8B 8E 48040000     - mov rcx,[rsi+00000448]
//! re9.exe+4D161A5 - 48 85 C9              - test rcx,rcx
//! re9.exe+4D161A8 - 75 90                 - jne re9.exe+4D1613A
//! re9.exe+4D161AA - 48 8B 4C 24 20        - mov rcx,[rsp+20]
//! re9.exe+4D161AF - E8 7C4B5E00           - call re9.exe+52FAD30
//! re9.exe+4D161B4 - 48 8B 4C 24 28        - mov rcx,[rsp+28]
//! re9.exe+4D161B9 - 48 31 E1              - xor rcx,rsp
//! re9.exe+4D161BC - E8 5F969D00           - call re9.AK::GetWindowsDeviceName+570
//! re9.exe+4D161C1 - 90                    - nop
//! re9.exe+4D161C2 - 48 83 C4 30           - add rsp,30
//! re9.exe+4D161C6 - 5B                    - pop rbx
//! re9.exe+4D161C7 - 5D                    - pop rbp
//! re9.exe+4D161C8 - 5F                    - pop rdi
//! re9.exe+4D161C9 - 5E                    - pop rsi
//! re9.exe+4D161CA - 41 5E                 - pop r14
//! re9.exe+4D161CC - C3                    - ret
//!

const std = @import("std");
const re = @import("reframework");
const win32 = @import("win32");

const interop = re.interop;

pub const NodeArray = extern struct {
    nodes: *TreeNode,
    len: u32,
};

pub const ManagedArray = extern struct {
    items: [*]re.sdk.ManagedObject,
    len: u32,
    capacity: u32,
};

pub const CoreHandleArray = extern struct {
    items: [*]CoreHandle,
    len: u32,
};

const managed_runtime_size = re.sdk.ManagedObject.runtime_size;

pub const BehaviorTree = extern struct {
    _obj_padding: [managed_runtime_size]u8 align(@alignOf(*anyopaque)),
    owner: re.sdk.ManagedObject, // via.GameObject
    child_component: ?*interop.ViaComponent,
    next_component: ?*interop.ViaComponent,
    prev_component: ?*interop.ViaComponent,
    trees: CoreHandleArray,
    queue_group: u32,
    index_in_queue: i32, // can be negative?
    padding2: [0xAC - (0x44 + @sizeOf(i32))]u8,
    can_execute: bool,
    padding3: [0xC0 - (0xAC + @sizeOf(bool))]u8,
    next: ?*BehaviorTree,
    prev: ?*BehaviorTree,
    queue_index: u32, // there are multiple BehaviorTree queue? and they each get turn to be executed?

    const trees_offset = re.sdk.ManagedObject.runtime_size + 0x20;
    const trees_count_offset = trees_offset + @sizeOf(*[*]*CoreHandle);
    const next_behavior_tree_offset = re.sdk.ManagedObject.runtime_size + 0xB0;
    const prev_behavior_tree_offset = re.sdk.ManagedObject.runtime_size + 0xB8;

    pub const full_type_name = "via.behaviortree.BehaviorTree";

    const Self = @This();

    pub inline fn fo(other_p: *anyopaque) *BehaviorTree {
        @setRuntimeSafety(false);
        return @ptrCast(@alignCast(other_p));
    }

    pub inline fn asComponent(self: *Self) *interop.ViaComponent {
        return @ptrCast(self);
    }

    pub inline fn vtable(self: *const Self) [*]const *const anyopaque {
        @setRuntimeSafety(false);
        const vtable_ptr: *const [*]const *const anyopaque = @ptrCast(@alignCast(self));
        return vtable_ptr.*;
    }

    pub fn getTrees(self: *const Self) []*CoreHandle {
        const ptr = @intFromPtr(self);
        const trees_count_ptr: *u32 = @ptrFromInt(ptr + trees_count_offset);
        const trees_ptr_ptr: *[*]*CoreHandle = @ptrFromInt(ptr + trees_offset);
        const trees_ptr = trees_ptr_ptr.*;
        return trees_ptr[0..trees_count_ptr.*];
    }

    pub fn startBehavior(self: *const Self, vm_context: ?*re.sdk.VmContext) void {
        // Might need to update for other version of the game. But usually per-engine version should be stable.
        // These are native engine objects interopped with il2cpp, so these usually don't change with game updates.
        const native_func_addr = self.vtable()[17];
        const native_func: *const fn (self: *const Self, context: ?*re.sdk.VmContext) callconv(.c) void = @ptrCast(native_func_addr);

        native_func(self, vm_context);
    }

    pub fn addToExecutionQueue(self: *Self) void {
        // Might need to update for other version of the game. But usually per-engine version should be stable.
        // These are native engine objects interopped with il2cpp, so these usually don't change with game updates.
        const native_func_addr = self.vtable()[8];
        const native_func: *const fn (self: *const Self) callconv(.c) void = @ptrCast(native_func_addr);

        native_func(self);
    }

    pub fn removeFromExecutionQueue(self: *Self) void {
        // Might need to update for other version of the game. But usually per-engine version should be stable.
        // These are native engine objects interopped with il2cpp, so these usually don't change with game updates.
        const native_func_addr = self.vtable()[9];
        const native_func: *const fn (self: *const Self) callconv(.c) void = @ptrCast(native_func_addr);

        native_func(self);
    }
};

comptime {
    std.debug.assert(@sizeOf(CoreHandleArray) == 0x10);
    std.debug.assert(@offsetOf(CoreHandleArray, "items") == 0x0);
    std.debug.assert(@offsetOf(CoreHandleArray, "len") == 0x8);
    std.debug.assert(@offsetOf(BehaviorTree, "trees") == 0x30);
    std.debug.assert(@offsetOf(BehaviorTree, "queue_group") == 0x40);
    std.debug.assert(@offsetOf(BehaviorTree, "index_in_queue") == 0x44);
    std.debug.assert(@offsetOf(BehaviorTree, "can_execute") == 0xAC);
    std.debug.assert(@offsetOf(BehaviorTree, "next") == 0xC0);
    std.debug.assert(@offsetOf(BehaviorTree, "prev") == 0xC8);
    std.debug.assert(@offsetOf(BehaviorTree, "queue_index") == 0xD0);
}

pub const CoreHandle = extern struct {
    _obj_padding: [re.sdk.ManagedObject.runtime_size]u8 align(@alignOf(*anyopaque)),
    _padding1: ?*anyopaque,
    core: Core,
};

pub const ActionArg = extern struct {
    _obj_padding: [re.sdk.ManagedObject.runtime_size]u8 align(@alignOf(*anyopaque)),
    owner_component: re.sdk.ManagedObject,
    owner_behavior_tree_core: *Core,
};

comptime {
    std.debug.assert(@offsetOf(ActionArg, "owner_component") == re.sdk.ManagedObject.runtime_size);
    std.debug.assert(@offsetOf(ActionArg, "owner_behavior_tree_core") == re.sdk.ManagedObject.runtime_size + @sizeOf(re.sdk.ManagedObject));
}

pub const Core = extern struct {
    vtable: **const anyopaque,
    tree_object: ?*const TreeObject,
    pad1: [0x30 - @sizeOf(*const TreeObject) - @sizeOf(**const anyopaque)]u8,
    selector_arg: re.sdk.ManagedObject, // via.behaviortree.SelectorArg
    action_arg: *ActionArg, // via.behaviortree.ActionArg
    condition_arg: re.sdk.ManagedObject, // via.behaviortree.ConditionArg
    selector_condition_arg: re.sdk.ManagedObject, // via.behaviortree.SelectorConditionArg
    selector_caller_arg: re.sdk.ManagedObject, // via.behaviortree.SelectorCallerArg
    transition_event_arg: re.sdk.ManagedObject, // via.behaviortree.TransitionEventArg
    user_variables_hub: re.sdk.ManagedObject, // via.userdata.UserVariablesHub
    maybe_next_component: ?*anyopaque,
    pad2: [0xB0 - 0x68 - @sizeOf(?*anyopaque)]u8,
    owner_component: re.sdk.ManagedObject,
};

comptime {
    std.debug.assert(@offsetOf(Core, "tree_object") == 0x8);
    std.debug.assert(@offsetOf(Core, "selector_arg") == 0x30);
    std.debug.assert(@offsetOf(Core, "action_arg") == 0x38);
    std.debug.assert(@offsetOf(Core, "condition_arg") == 0x40);
    std.debug.assert(@offsetOf(Core, "selector_condition_arg") == 0x48);
    std.debug.assert(@offsetOf(Core, "selector_caller_arg") == 0x50);
    std.debug.assert(@offsetOf(Core, "transition_event_arg") == 0x58);
    std.debug.assert(@offsetOf(Core, "user_variables_hub") == 0x60);
    std.debug.assert(@offsetOf(Core, "maybe_next_component") == 0x68);
    std.debug.assert(@offsetOf(Core, "owner_component") == 0xB0);
}

pub const TreeObject = extern struct {
    vfptr: *const anyopaque,
    pad1: [0x20 - @sizeOf(?*anyopaque)]u8,
    data: ?*TreeObjectData,
    nodes: NodeArray,
    pad2: [0x48 - 0x28 - @sizeOf(NodeArray)]u8,
    actions: ManagedArray,
    pad3: [0xB8 - 0x48 - @sizeOf(ManagedArray)]u8,
    selectors: ManagedArray,
};

comptime {
    std.debug.assert(@offsetOf(TreeObject, "data") == 0x20);
    std.debug.assert(@offsetOf(TreeObject, "nodes") == 0x28);
    std.debug.assert(@offsetOf(TreeObject, "actions") == 0x48);
    std.debug.assert(@offsetOf(TreeObject, "selectors") == 0xB8);
}

pub const TreeObjectData = extern struct {
    pad1: [0xB0]u8 align(@alignOf(*anyopaque)),
    some_count: u32,
};

comptime {
    std.debug.assert(@offsetOf(TreeObjectData, "some_count") == 0xB0);
}

pub const TreeNode = opaque {};
