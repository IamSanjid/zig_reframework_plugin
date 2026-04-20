const std = @import("std");
const API = @import("API");
const Verified = @import("../verified.zig").Verified;
const TypeDefinition = @import("TypeDefinition.zig");

raw: API.REFrameworkFieldHandle,

const Field = @This();

pub inline fn handle(self: Field) API.REFrameworkFieldHandle {
    return self.raw;
}

pub fn getName(self: Field, sdk: Verified(API.REFrameworkSDKData, .{ .field = .get_name })) ?[:0]const u8 {
    const value = sdk.safe().field.safe().get_name(self.handle()) orelse return null;
    return std.mem.span(value);
}

pub fn getDeclaringType(self: Field, sdk: Verified(API.REFrameworkSDKData, .{ .field = .get_declaring_type })) ?TypeDefinition {
    const result = sdk.safe().field.safe().get_declaring_type(self.handle());
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub fn getType(self: Field, sdk: Verified(API.REFrameworkSDKData, .{ .field = .get_type })) ?TypeDefinition {
    const result = sdk.safe().field.safe().get_type(self.handle());
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub fn getOffsetFromBase(self: Field, sdk: Verified(API.REFrameworkSDKData, .{ .field = .get_offset_from_base })) u32 {
    return sdk.safe().field.safe().get_offset_from_base(self.handle());
}

pub fn getOffsetFromFieldptr(self: Field, sdk: Verified(API.REFrameworkSDKData, .{ .field = .get_offset_from_fieldptr })) u32 {
    return sdk.safe().field.safe().get_offset_from_fieldptr(self.handle());
}

pub fn getFlags(self: Field, sdk: Verified(API.REFrameworkSDKData, .{ .field = .get_flags })) u32 {
    return sdk.safe().field.safe().get_flags(self.handle());
}

pub fn isStatic(self: Field, sdk: Verified(API.REFrameworkSDKData, .{ .field = .is_static })) bool {
    return sdk.safe().field.safe().is_static(self.handle());
}

pub fn isLiteral(self: Field, sdk: Verified(API.REFrameworkSDKData, .{ .field = .is_literal })) bool {
    return sdk.safe().field.safe().is_literal(self.handle());
}

pub fn getInitData(self: Field, sdk: Verified(API.REFrameworkSDKData, .{ .field = .get_init_data })) ?*anyopaque {
    return sdk.safe().field.safe().get_init_data(self.handle());
}

pub fn getDataRaw(
    self: Field,
    sdk: Verified(API.REFrameworkSDKData, .{ .field = .get_data_raw }),
    obj: ?*anyopaque,
    is_value_type: bool,
) ?*anyopaque {
    return sdk.safe().field.safe().get_data_raw(self.handle(), obj, is_value_type);
}

pub fn getIndex(self: Field, sdk: Verified(API.REFrameworkSDKData, .{ .field = .get_index })) u32 {
    return sdk.safe().field.safe().get_index(self.handle());
}
