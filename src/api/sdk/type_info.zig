const std = @import("std");
const API = @import("API");
const Verified = @import("../verified.zig").Verified;
const ReflectionMethod = @import("reflection_method.zig").ReflectionMethod;
const ReflectionProperty = @import("reflection_property.zig").ReflectionProperty;
const TypeDefinition = @import("type_definition.zig").TypeDefinition;

pub const TypeInfo = extern struct {
    raw: API.REFrameworkTypeInfoHandle,

    const Self = @This();

    pub inline fn handle(self: Self) API.REFrameworkTypeInfoHandle {
        return self.raw;
    }

    pub inline fn getName(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .get_name })) ?[:0]const u8 {
        const value = sdk.safe().type_info.safe().get_name(self.handle()) orelse return null;
        return std.mem.span(value);
    }

    pub inline fn getTypeDefinition(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .get_type_definition })) ?TypeDefinition {
        const result = sdk.safe().type_info.safe().get_type_definition(self.handle());
        return if (result) |value| .{ .raw = @ptrCast(value) } else null;
    }

    pub inline fn isClrType(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .is_clr_type })) bool {
        return sdk.safe().type_info.safe().is_clr_type(self.handle());
    }

    pub inline fn isSingleton(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .is_singleton })) bool {
        return sdk.safe().type_info.safe().is_singleton(self.handle());
    }

    pub inline fn getSingletonInstance(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .get_singleton_instance })) ?*anyopaque {
        return sdk.safe().type_info.safe().get_singleton_instance(self.handle());
    }

    pub inline fn getReflectionPropertyDescriptor(
        self: Self,
        sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .get_reflection_property_descriptor }),
        name: [:0]const u8,
    ) ?ReflectionProperty {
        const result = sdk.safe().type_info.safe().get_reflection_property_descriptor(self.handle(), name.ptr);
        return if (result) |value| .{ .raw = @ptrCast(value) } else null;
    }

    pub inline fn getReflectionMethodDescriptor(
        self: Self,
        sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .get_reflection_method_descriptor }),
        name: [:0]const u8,
    ) ?ReflectionMethod {
        const result = sdk.safe().type_info.safe().get_reflection_method_descriptor(self.handle(), name.ptr);
        return if (result) |value| .{ .raw = @ptrCast(value) } else null;
    }

    pub inline fn getDeserializerFn(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .get_deserializer_fn })) ?*anyopaque {
        return sdk.safe().type_info.safe().get_deserializer_fn(self.handle());
    }

    pub inline fn getParent(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .get_parent })) ?Self {
        const result = sdk.safe().type_info.safe().get_parent(self.handle());
        return if (result) |value| .{ .raw = @ptrCast(value) } else null;
    }

    pub inline fn getCrc(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .type_info = .get_crc })) u32 {
        return sdk.safe().type_info.safe().get_crc(self.handle());
    }
};