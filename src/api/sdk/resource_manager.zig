const API = @import("API");
const Verified = @import("../verified.zig").Verified;
const ManagedObject = @import("managed_object.zig").ManagedObject;
const Resource = @import("resource.zig").Resource;

pub const ResourceManager = extern struct {
    raw: API.REFrameworkResourceManagerHandle,

    const Self = @This();

    pub inline fn handle(self: Self) API.REFrameworkResourceManagerHandle {
        return self.raw;
    }

    pub inline fn createResource(
        self: Self,
        sdk: Verified(API.REFrameworkSDKData, .{ .resource_manager = .create_resource }),
        type_name: [:0]const u8,
        name: [:0]const u8,
    ) ?Resource {
        const result = sdk.safe().resource_manager.safe().create_resource(self.handle(), type_name.ptr, name.ptr);
        return if (result) |value| .{ .raw = @ptrCast(value) } else null;
    }

    pub inline fn createUserdata(
        self: Self,
        sdk: Verified(API.REFrameworkSDKData, .{ .resource_manager = .create_userdata }),
        type_name: [:0]const u8,
        name: [:0]const u8,
    ) ?ManagedObject {
        const result = sdk.safe().resource_manager.safe().create_userdata(self.handle(), type_name.ptr, name.ptr);
        return if (result) |value| .{ .raw = @ptrCast(value) } else null;
    }
};