const API = @import("API");
const Verified = @import("../verified.zig").Verified;
const ManagedObject = @import("ManagedObject.zig");
const Resource = @import("Resource.zig");

raw: API.REFrameworkResourceManagerHandle,

const ResourceManager = @This();

pub inline fn handle(self: ResourceManager) API.REFrameworkResourceManagerHandle {
    return self.raw;
}

pub inline fn createResource(
    self: ResourceManager,
    sdk: Verified(API.REFrameworkSDKData, .{ .resource_manager = .create_resource }),
    type_name: [:0]const u8,
    name: [:0]const u8,
) ?Resource {
    const result = sdk.safe().resource_manager.safe().create_resource(self.handle(), type_name.ptr, name.ptr);
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub inline fn createUserdata(
    self: ResourceManager,
    sdk: Verified(API.REFrameworkSDKData, .{ .resource_manager = .create_userdata }),
    type_name: [:0]const u8,
    name: [:0]const u8,
) ?ManagedObject {
    const result = sdk.safe().resource_manager.safe().create_userdata(self.handle(), type_name.ptr, name.ptr);
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}
