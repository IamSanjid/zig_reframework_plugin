const API = @import("API");
const Verified = @import("../verified.zig").Verified;

pub const ReflectionProperty = extern struct {
    raw: API.REFrameworkReflectionPropertyHandle,

    const Self = @This();

    pub inline fn handle(self: Self) API.REFrameworkReflectionPropertyHandle {
        return self.raw;
    }

    pub inline fn getGetter(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .reflection_property = .get_getter })) API.REFrameworkReflectionPropertyMethod {
        return sdk.safe().reflection_property.safe().get_getter(self.handle());
    }

    pub inline fn isStatic(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .reflection_property = .is_static })) bool {
        return sdk.safe().reflection_property.safe().is_static(self.handle());
    }

    pub inline fn getSize(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .reflection_property = .get_size })) u32 {
        return sdk.safe().reflection_property.safe().get_size(self.handle());
    }
};