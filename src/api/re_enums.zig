const API = @import("API");

pub const HookCall = enum(i32) {
    call_original,
    skip_original,
};

pub const CreateInstanceFlags = enum(i32) {
    none,
    simplify,
};

pub const VmObjType = enum(i32) {
    null,
    object,
    array,
    string,
    delegate,
    valtype,
    unknown,

    pub fn fromU32(v: u32) @This() {
        return switch (v) {
            API.REFRAMEWORK_VM_OBJ_TYPE_NULL => .null,
            API.REFRAMEWORK_VM_OBJ_TYPE_OBJECT => .object,
            API.REFRAMEWORK_VM_OBJ_TYPE_ARRAY => .array,
            API.REFRAMEWORK_VM_OBJ_TYPE_STRING => .string,
            API.REFRAMEWORK_VM_OBJ_TYPE_DELEGATE => .delegate,
            API.REFRAMEWORK_VM_OBJ_TYPE_VALTYPE => .valtype,
            else => .unknown,
        };
    }
};

pub const RendererType = enum(i32) {
    d3d11 = 0,
    d3d12,
    unknown,

    pub fn fromU32(v: u32) @This() {
        return switch (v) {
            API.REFRAMEWORK_RENDERER_D3D11 => .d3d11,
            API.REFRAMEWORK_RENDERER_D3D12 => .d3d12,
            else => .unknown,
        };
    }
};
