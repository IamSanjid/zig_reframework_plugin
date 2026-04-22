const std = @import("std");
const API = @import("API");
const Verified = @import("../verified.zig").Verified;

raw: API.REFrameworkModuleHandle,

const Module = @This();

pub inline fn handle(self: Module) API.REFrameworkModuleHandle {
    return self.raw;
}

pub inline fn getMajor(self: Module, sdk: Verified(API.REFrameworkSDKData, .{ .module = .get_major })) u16 {
    return sdk.safe().module.safe().get_major(self.handle());
}

pub inline fn getMinor(self: Module, sdk: Verified(API.REFrameworkSDKData, .{ .module = .get_minor })) u16 {
    return sdk.safe().module.safe().get_minor(self.handle());
}

pub inline fn getBuild(self: Module, sdk: Verified(API.REFrameworkSDKData, .{ .module = .get_build })) u16 {
    return sdk.safe().module.safe().get_build(self.handle());
}

pub inline fn getRevision(self: Module, sdk: Verified(API.REFrameworkSDKData, .{ .module = .get_revision })) u16 {
    return sdk.safe().module.safe().get_revision(self.handle());
}

pub inline fn getAssemblyName(self: Module, sdk: Verified(API.REFrameworkSDKData, .{ .module = .get_assembly_name })) ?[:0]const u8 {
    const value = sdk.safe().module.safe().get_assembly_name(self.handle()) orelse return null;
    return std.mem.span(value);
}

pub inline fn getLocation(self: Module, sdk: Verified(API.REFrameworkSDKData, .{ .module = .get_location })) ?[:0]const u8 {
    const value = sdk.safe().module.safe().get_location(self.handle()) orelse return null;
    return std.mem.span(value);
}

pub inline fn getModuleName(self: Module, sdk: Verified(API.REFrameworkSDKData, .{ .module = .get_module_name })) ?[:0]const u8 {
    const value = sdk.safe().module.safe().get_module_name(self.handle()) orelse return null;
    return std.mem.span(value);
}

pub inline fn getTypes(self: Module, sdk: Verified(API.REFrameworkSDKData, .{ .module = .{ .get_types, .get_num_types } })) []u32 {
    const ptr = sdk.safe().module.safe().get_types(self.handle());
    const len = sdk.safe().module.safe().get_num_types(self.handle());
    return ptr[0..len];
}

pub inline fn getMethods(self: Module, sdk: Verified(API.REFrameworkSDKData, .{ .module = .{ .get_methods, .get_num_methods } })) []u32 {
    const ptr = sdk.safe().module.safe().get_methods(self.handle());
    const len = sdk.safe().module.safe().get_num_methods(self.handle());
    return ptr[0..len];
}
