const std = @import("std");
const API = @import("API");
const Verified = @import("../verified.zig").Verified;
const ReflectionMethod = @import("ReflectionMethod.zig");
const ReflectionProperty = @import("ReflectionProperty.zig");
const TypeDefinition = @import("TypeDefinition.zig");

raw: API.REFrameworkTypeInfoHandle,

const TypeInfo = @This();

pub inline fn handle(self: TypeInfo) API.REFrameworkTypeInfoHandle {
    return self.raw;
}

pub fn getName(self: TypeInfo, sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .get_name })) ?[:0]const u8 {
    const value = sdk.safe().type_info.safe().get_name(self.handle()) orelse return null;
    return std.mem.span(value);
}

pub fn getTypeDefinition(self: TypeInfo, sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .get_type_definition })) ?TypeDefinition {
    const result = sdk.safe().type_info.safe().get_type_definition(self.handle());
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub fn isClrType(self: TypeInfo, sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .is_clr_type })) bool {
    return sdk.safe().type_info.safe().is_clr_type(self.handle());
}

pub fn isSingleton(self: TypeInfo, sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .is_singleton })) bool {
    return sdk.safe().type_info.safe().is_singleton(self.handle());
}

pub fn getSingletonInstance(self: TypeInfo, sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .get_singleton_instance })) ?*anyopaque {
    return sdk.safe().type_info.safe().get_singleton_instance(self.handle());
}

pub fn getReflectionPropertyDescriptor(
    self: TypeInfo,
    sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .get_reflection_property_descriptor }),
    name: [:0]const u8,
) ?ReflectionProperty {
    const result = sdk.safe().type_info.safe().get_reflection_property_descriptor(self.handle(), name.ptr);
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub fn getReflectionMethodDescriptor(
    self: TypeInfo,
    sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .get_reflection_method_descriptor }),
    name: [:0]const u8,
) ?ReflectionMethod {
    const result = sdk.safe().type_info.safe().get_reflection_method_descriptor(self.handle(), name.ptr);
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub fn getDeserializerFn(self: TypeInfo, sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .get_deserializer_fn })) ?*anyopaque {
    return sdk.safe().type_info.safe().get_deserializer_fn(self.handle());
}

pub fn getParent(self: TypeInfo, sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .get_parent })) ?TypeInfo {
    const result = sdk.safe().type_info.safe().get_parent(self.handle());
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub fn getCrc(self: TypeInfo, sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .get_crc })) u32 {
    return sdk.safe().type_info.safe().get_crc(self.handle());
}
