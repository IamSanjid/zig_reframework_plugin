pub const Field = @import("sdk/Field.zig");
pub const ManagedObject = @import("sdk/ManagedObject.zig");
pub const Method = @import("sdk/Method.zig");
pub const Module = @import("sdk/Module.zig");
pub const Property = @import("sdk/Property.zig");
pub const ReflectionMethod = @import("sdk/ReflectionMethod.zig");
pub const ReflectionProperty = @import("sdk/ReflectionProperty.zig");
pub const Resource = @import("sdk/Resource.zig");
pub const ResourceManager = @import("sdk/ResourceManager.zig");
pub const Tdb = @import("sdk/Tdb.zig");
pub const TypeDefinition = @import("sdk/TypeDefinition.zig");
pub const TypeInfo = @import("sdk/TypeInfo.zig");
pub const VmContext = @import("sdk/VmContext.zig");

const API = @import("API");
const Verified = @import("verified.zig").Verified;

const VerifiedSdk = Verified(API.REFrameworkSDKData, .{});

pub fn getTdb(vsdk: VerifiedSdk.Extend(.{ .functions = .get_tdb })) ?Tdb {
    const handle = vsdk.safe().functions.safe().get_tdb() orelse null;
    return .{ .raw = @ptrCast(handle) };
}

pub fn getResourceManager(vsdk: VerifiedSdk.Extend(.{ .functions = .get_resource_manager })) ?ResourceManager {
    const handle = vsdk.safe().functions.safe().get_resource_manager() orelse null;
    return .{ .raw = @ptrCast(handle) };
}

pub fn getVmContext(vsdk: VerifiedSdk.Extend(.{ .functions = .get_vm_context })) ?VmContext {
    const handle = vsdk.safe().functions.safe().get_vm_context() orelse null;
    return .{ .raw = @ptrCast(handle) };
}

pub fn typeof(vsdk: VerifiedSdk.Extend(.{ .functions = .typeof_ }), type_name: [:0]const u8) ?ManagedObject {
    const handle = vsdk.safe().functions.safe().typeof_(@ptrCast(type_name.ptr)) orelse null;
    return .{ .raw = @ptrCast(handle) };
}

pub fn getManagedSingleton(vsdk: VerifiedSdk.Extend(.{ .functions = .get_managed_singleton }), type_name: [:0]const u8) ?ManagedObject {
    const handle = vsdk.safe().functions.safe().get_managed_singleton(@ptrCast(type_name.ptr)) orelse null;
    return .{ .raw = @ptrCast(handle) };
}

pub fn getNativeSingleton(vsdk: VerifiedSdk.Extend(.{ .functions = .get_native_singleton }), type_name: [:0]const u8) ?*anyopaque {
    const handle = vsdk.safe().functions.safe().get_native_singleton(@ptrCast(type_name.ptr)) orelse null;
    return @ptrCast(handle);
}

pub fn createManagedString(vsdk: VerifiedSdk.Extend(.{ .functions = .create_managed_string }), str: [:0]const u16) ?ManagedObject {
    const handle = vsdk.safe().functions.safe().create_managed_string(@ptrCast(str.ptr)) orelse null;
    return .{ .raw = @ptrCast(handle) };
}

pub fn createManagedStringNormal(vsdk: VerifiedSdk.Extend(.{ .functions = .create_managed_string_normal }), str: [:0]const u8) ?ManagedObject {
    const handle = vsdk.safe().functions.safe().create_managed_string_normal(@ptrCast(str.ptr)) orelse null;
    return .{ .raw = @ptrCast(handle) };
}

// Zig level std.mem.Allocator is fine, but just in-case
pub fn allocate(vsdk: VerifiedSdk.Extend(.{ .functions = .allocate }), size: u64) ?*anyopaque {
    return vsdk.safe().functions.safe().allocate(size);
}

pub fn deallocate(vsdk: VerifiedSdk.Extend(.{ .functions = .deallocate }), ptr: *anyopaque) void {
    vsdk.safe().functions.safe().deallocate(ptr);
}

test {
    @import("std").testing.refAllDecls(@This());
}
