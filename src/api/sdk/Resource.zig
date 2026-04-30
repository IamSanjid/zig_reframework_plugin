const API = @import("API");
const Verified = @import("../verified.zig").Verified;
const ManagedObject = @import("managed_object.zig").ManagedObject;

pub const Resource = extern struct {
    raw: API.REFrameworkResourceHandle,

    const Self = @This();

    pub inline fn handle(self: Self) API.REFrameworkResourceHandle {
        return self.raw;
    }

    pub inline fn addRef(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .resource = .add_ref })) void {
        sdk.safe().resource.safe().add_ref(self.handle());
    }

    pub inline fn release(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .resource = .release })) void {
        sdk.safe().resource.safe().release(self.handle());
    }

    pub inline fn createHolder(
        self: Self,
        sdk: Verified(API.REFrameworkSDKData, .{ .resource = .create_holder }),
        type_name: [:0]const u8,
    ) ?ManagedObject {
        const result = sdk.safe().resource.safe().create_holder(self.handle(), type_name.ptr);
        return if (result) |value| .{ .raw = @ptrCast(value) } else null;
    }
};