const API = @import("API");
const Verified = @import("../verified.zig").Verified;
const InvokeRet = @import("../invoke_ret.zig").InvokeRet;

const re_error = @import("../re_error.zig");
const REFrameworkError = re_error.REFrameworkError;
const VmObjType = @import("../re_enums.zig").VmObjType;
const Method = @import("Method.zig");
const ReflectionMethod = @import("ReflectionMethod.zig");
const ReflectionProperty = @import("ReflectionProperty.zig");
const TypeDefinition = @import("TypeDefinition.zig");
const TypeInfo = @import("TypeInfo.zig");

raw: API.REFrameworkManagedObjectHandle,

const ManagedObject = @This();

pub const runtime_size = @import("../../root.zig").options.managed_object_runtime_size;

pub inline fn handle(self: ManagedObject) API.REFrameworkManagedObjectHandle {
    return self.raw;
}

pub inline fn addRef(self: ManagedObject, sdk: Verified(API.REFrameworkSDKData, .{ .managed_object = .add_ref })) void {
    sdk.safe().managed_object.safe().add_ref(self.handle());
}

pub inline fn release(self: ManagedObject, sdk: Verified(API.REFrameworkSDKData, .{ .managed_object = .release })) void {
    sdk.safe().managed_object.safe().release(self.handle());
}

pub inline fn getTypeDefinition(self: ManagedObject, sdk: Verified(API.REFrameworkSDKData, .{ .managed_object = .get_type_definition })) ?TypeDefinition {
    const result = sdk.safe().managed_object.safe().get_type_definition(self.handle());
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub inline fn isManagedObject(self: ManagedObject, sdk: Verified(API.REFrameworkSDKData, .{ .managed_object = .is_managed_object })) bool {
    return sdk.safe().managed_object.safe().is_managed_object(@ptrCast(self.handle()));
}

pub inline fn getRefCount(self: ManagedObject, sdk: Verified(API.REFrameworkSDKData, .{ .managed_object = .get_ref_count })) u32 {
    return sdk.safe().managed_object.safe().get_ref_count(self.handle());
}

pub inline fn getVmObjType(self: ManagedObject, sdk: Verified(API.REFrameworkSDKData, .{ .managed_object = .get_vm_obj_type })) VmObjType {
    return .fromU32(sdk.safe().managed_object.safe().get_vm_obj_type(self.handle()));
}

pub inline fn getTypeInfo(self: ManagedObject, sdk: Verified(API.REFrameworkSDKData, .{ .managed_object = .get_type_info })) ?TypeInfo {
    const result = sdk.safe().managed_object.safe().get_type_info(self.handle());
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub inline fn getReflectionPropertyDescriptor(
    self: ManagedObject,
    sdk: Verified(API.REFrameworkSDKData, .{ .managed_object = .get_reflection_property_descriptor }),
    name: [:0]const u8,
) ?ReflectionProperty {
    const result = sdk.safe().managed_object.safe().get_reflection_property_descriptor(self.handle(), name.ptr);
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub inline fn getReflectionMethodDescriptor(
    self: ManagedObject,
    sdk: Verified(API.REFrameworkSDKData, .{ .managed_object = .get_reflection_method_descriptor }),
    name: [:0]const u8,
) ?ReflectionMethod {
    const result = sdk.safe().managed_object.safe().get_reflection_method_descriptor(self.handle(), name.ptr);
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub fn invokeMethod(
    self: ManagedObject,
    method: Method,
    sdk: Verified(API.REFrameworkSDKData, .{ .method = .invoke }),
    args: []?*anyopaque,
) REFrameworkError!InvokeRet {
    var out: InvokeRet = .{};
    const result = sdk.safe().method.safe().invoke(
        method.handle(),
        @ptrCast(self.handle()),
        if (args.len == 0) null else @ptrCast(args.ptr),
        @intCast(args.len * @sizeOf(?*anyopaque)),
        &out,
        @sizeOf(InvokeRet),
    );
    try re_error.mapResult(result);
    return out;
}
