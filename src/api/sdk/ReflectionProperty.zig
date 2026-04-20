const API = @import("API");
const Verified = @import("../verified.zig").Verified;

const ReflectionProperty = @This();

raw: API.REFrameworkReflectionPropertyHandle,

pub inline fn handle(self: ReflectionProperty) API.REFrameworkReflectionPropertyHandle {
    return self.raw;
}

pub fn getGetter(self: ReflectionProperty, sdk: Verified(API.REFrameworkSDKData, .{ .reflection_property = .get_getter })) API.REFrameworkReflectionPropertyMethod {
    return sdk.safe().reflection_property.safe().get_getter(self.handle());
}

pub fn isStatic(self: ReflectionProperty, sdk: Verified(API.REFrameworkSDKData, .{ .reflection_property = .is_static })) bool {
    return sdk.safe().reflection_property.safe().is_static(self.handle());
}

pub fn getSize(self: ReflectionProperty, sdk: Verified(API.REFrameworkSDKData, .{ .reflection_property = .get_size })) u32 {
    return sdk.safe().reflection_property.safe().get_size(self.handle());
}

test "reflection property" {
    const std = @import("std");
    const DummyStruct = struct {
        fn dummy(h: API.REFrameworkReflectionPropertyHandle) callconv(.c) API.REFrameworkReflectionPropertyMethod {
            return @ptrCast(h);
        }
    };

    var reflection_property: API.REFrameworkReflectionProperty = .{
        .get_getter = &DummyStruct.dummy,
    };

    const sdk: API.REFrameworkSDKData = .{
        .reflection_property = &reflection_property,
    };

    var dummy_handle: API.struct_REFrameworkPropertyHandle__ = undefined;

    const z_reflection_property: ReflectionProperty = .{ .raw = @ptrCast(&dummy_handle) };

    const VerifiedSDK = Verified(API.REFrameworkSDKData, .{ .reflection_property = .get_getter });
    const verified_sdk = try VerifiedSDK.init(&sdk);

    const orig_handle: usize = @intFromPtr(z_reflection_property.raw);
    const returned_handle: usize = @intFromPtr(z_reflection_property.getGetter(.fromOther(verified_sdk)));

    try std.testing.expectEqual(orig_handle, returned_handle);
}
