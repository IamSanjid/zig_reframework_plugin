const std = @import("std");

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

const re_error = @import("re_error.zig");
const REFrameworkError = re_error.REFrameworkError;

const VerifiedSdk = Verified(API.REFrameworkSDKData, .{});

pub const ManagedSingleton = struct {
    raw: API.REFrameworkManagedSingleton,

    const Self = @This();

    pub inline fn instance(self: Self) ManagedObject {
        return .{ .raw = self.raw.instance };
    }

    pub inline fn typeDefinition(self: Self) TypeDefinition {
        return .{ .raw = self.raw.t };
    }

    pub inline fn typeInfo(self: Self) TypeInfo {
        return .{ .raw = self.raw.type_info };
    }
};

comptime {
    @import("std").debug.assert(@sizeOf(ManagedSingleton) == @sizeOf(API.REFrameworkManagedSingleton));
    @import("std").debug.assert(@alignOf(ManagedSingleton) == @alignOf(API.REFrameworkManagedSingleton));
}

pub const NativeSingleton = struct {
    raw: API.REFrameworkNativeSingleton,

    const Self = @This();

    pub inline fn instance(self: Self) ?*anyopaque {
        return self.raw.instance;
    }

    pub inline fn typeDefinition(self: Self) TypeDefinition {
        return .{ .raw = self.raw.t };
    }

    pub inline fn typeInfo(self: Self) TypeInfo {
        return .{ .raw = self.raw.type_info };
    }

    pub inline fn name(self: Self) [:0]const u8 {
        return std.mem.span(self.raw.name);
    }
};

pub inline fn getTdb(vsdk: VerifiedSdk.Extend(.{ .functions = .get_tdb })) ?Tdb {
    const handle = vsdk.safe().functions.safe().get_tdb() orelse null;
    return .{ .raw = @ptrCast(handle) };
}

pub inline fn getResourceManager(vsdk: VerifiedSdk.Extend(.{ .functions = .get_resource_manager })) ?ResourceManager {
    const handle = vsdk.safe().functions.safe().get_resource_manager() orelse null;
    return .{ .raw = @ptrCast(handle) };
}

pub inline fn getVmContext(vsdk: VerifiedSdk.Extend(.{ .functions = .get_vm_context })) ?VmContext {
    const handle = vsdk.safe().functions.safe().get_vm_context() orelse null;
    return .{ .raw = @ptrCast(handle) };
}

pub inline fn typeof(vsdk: VerifiedSdk.Extend(.{ .functions = .typeof_ }), type_name: [:0]const u8) ?ManagedObject {
    const handle = vsdk.safe().functions.safe().typeof_(@ptrCast(type_name.ptr)) orelse null;
    return .{ .raw = @ptrCast(handle) };
}

pub inline fn getManagedSingleton(vsdk: VerifiedSdk.Extend(.{ .functions = .get_managed_singleton }), type_name: [:0]const u8) ?ManagedObject {
    const handle = vsdk.safe().functions.safe().get_managed_singleton(@ptrCast(type_name.ptr)) orelse null;
    return .{ .raw = @ptrCast(handle) };
}

pub inline fn getNativeSingleton(vsdk: VerifiedSdk.Extend(.{ .functions = .get_native_singleton }), type_name: [:0]const u8) ?*anyopaque {
    const handle = vsdk.safe().functions.safe().get_native_singleton(@ptrCast(type_name.ptr)) orelse null;
    return @ptrCast(handle);
}

pub fn getManagedSingletons(vsdk: VerifiedSdk.Extend(.{ .functions = .get_managed_singletons }), out: []ManagedSingleton) ![]ManagedSingleton {
    var out_count: c_uint = 0;
    const result = vsdk.safe().functions.safe().get_managed_singletons(
        @ptrCast(out.ptr),
        @intCast(out.len * @sizeOf(ManagedSingleton)),
        &out_count,
    );
    try re_error.mapResult(result);
    if (out_count > out.len) return error.OutTooSmall;
    return out[0..out_count];
}

pub fn getNativeSingletons(vsdk: VerifiedSdk.Extend(.{ .functions = .get_native_singletons }), out: []NativeSingleton) ![]NativeSingleton {
    var out_count: c_uint = 0;
    const result = vsdk.safe().functions.safe().get_native_singletons(
        @ptrCast(out.ptr),
        @intCast(out.len * @sizeOf(NativeSingleton)),
        &out_count,
    );
    try re_error.mapResult(result);
    if (out_count > out.len) return error.OutTooSmall;
    return out[0..out_count];
}

pub inline fn createManagedString(vsdk: VerifiedSdk.Extend(.{ .functions = .create_managed_string }), str: [:0]const u16) ?ManagedObject {
    const handle = vsdk.safe().functions.safe().create_managed_string(@ptrCast(str.ptr)) orelse null;
    return .{ .raw = @ptrCast(handle) };
}

pub inline fn createManagedStringNormal(vsdk: VerifiedSdk.Extend(.{ .functions = .create_managed_string_normal }), str: [:0]const u8) ?ManagedObject {
    const handle = vsdk.safe().functions.safe().create_managed_string_normal(@ptrCast(str.ptr)) orelse null;
    return .{ .raw = @ptrCast(handle) };
}

// Zig level std.mem.Allocator is fine, but just in-case
pub inline fn allocate(vsdk: VerifiedSdk.Extend(.{ .functions = .allocate }), size: u64) ?*anyopaque {
    return vsdk.safe().functions.safe().allocate(size);
}

pub inline fn deallocate(vsdk: VerifiedSdk.Extend(.{ .functions = .deallocate }), ptr: *anyopaque) void {
    vsdk.safe().functions.safe().deallocate(ptr);
}

test {
    @import("std").testing.refAllDecls(@This());
}
