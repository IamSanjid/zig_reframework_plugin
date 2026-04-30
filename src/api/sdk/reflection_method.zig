const API = @import("API");
const Verified = @import("../verified.zig").Verified;

pub const ReflectionMethod = extern struct {
    raw: API.REFrameworkReflectionMethodHandle,

    const Self = @This();

    pub inline fn handle(self: Self) API.REFrameworkReflectionMethodHandle {
        return self.raw;
    }

    pub inline fn getFunction(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .reflection_method = .get_function })) API.REFrameworkInvokeMethod {
        return sdk.safe().reflection_method.safe().get_function(self.handle());
    }
};