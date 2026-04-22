const API = @import("API");
const Verified = @import("../verified.zig").Verified;

const ReflectionMethod = @This();

raw: API.REFrameworkReflectionMethodHandle,

pub inline fn handle(self: ReflectionMethod) API.REFrameworkReflectionMethodHandle {
    return self.raw;
}

pub inline fn getFunction(self: ReflectionMethod, sdk: Verified(API.REFrameworkSDKData, .{ .reflection_method = .get_function })) API.REFrameworkInvokeMethod {
    return sdk.safe().reflection_method.safe().get_function(self.handle());
}

test "reflection method" {
    const std = @import("std");
    const DummyStruct = struct {
        fn dummy(h: API.REFrameworkReflectionMethodHandle) callconv(.c) API.REFrameworkInvokeMethod {
            return @ptrCast(h);
        }
    };

    var reflection_method: API.REFrameworkReflectionMethod = .{
        .get_function = &DummyStruct.dummy,
    };

    const sdk: API.REFrameworkSDKData = .{
        .reflection_method = &reflection_method,
    };

    var dummy_handle: API.struct_REFrameworkModuleHandle__ = undefined;

    const z_reflection_method: ReflectionMethod = .{ .raw = @ptrCast(&dummy_handle) };

    const VerifiedSDK = Verified(API.REFrameworkSDKData, .{ .reflection_method = .get_function });
    const verified_sdk = try VerifiedSDK.init(&sdk);

    const orig_handle: usize = @intFromPtr(z_reflection_method.raw);
    const returned_handle: usize = @intFromPtr(z_reflection_method.getFunction(.fromOther(verified_sdk)));

    try std.testing.expectEqual(orig_handle, returned_handle);
}
