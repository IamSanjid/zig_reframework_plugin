const std = @import("std");
const API = @import("API");
const Verified = @import("../verified.zig").Verified;
const TypeDefinition = @import("type_definition.zig").TypeDefinition;

pub const Field = extern struct {
    raw: API.REFrameworkFieldHandle,

    const Self = @This();

    pub inline fn handle(self: Self) API.REFrameworkFieldHandle {
        return self.raw;
    }

    pub inline fn getName(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .field = .get_name })) ?[:0]const u8 {
        const value = sdk.safe().field.safe().get_name(self.handle()) orelse return null;
        return std.mem.span(value);
    }

    pub inline fn getDeclaringType(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .field = .get_declaring_type })) ?TypeDefinition {
        const result = sdk.safe().field.safe().get_declaring_type(self.handle());
        return if (result) |value| .{ .raw = @ptrCast(value) } else null;
    }

    pub inline fn getType(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .field = .get_type })) ?TypeDefinition {
        const result = sdk.safe().field.safe().get_type(self.handle());
        return if (result) |value| .{ .raw = @ptrCast(value) } else null;
    }

    pub inline fn getOffsetFromBase(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .field = .get_offset_from_base })) u32 {
        return sdk.safe().field.safe().get_offset_from_base(self.handle());
    }

    pub inline fn getOffsetFromFieldptr(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .field = .get_offset_from_fieldptr })) u32 {
        return sdk.safe().field.safe().get_offset_from_fieldptr(self.handle());
    }

    pub inline fn getFlags(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .field = .get_flags })) u32 {
        return sdk.safe().field.safe().get_flags(self.handle());
    }

    pub inline fn isStatic(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .field = .is_static })) bool {
        return sdk.safe().field.safe().is_static(self.handle());
    }

    pub inline fn isLiteral(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .field = .is_literal })) bool {
        return sdk.safe().field.safe().is_literal(self.handle());
    }

    pub inline fn getInitData(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .field = .get_init_data })) ?*anyopaque {
        return sdk.safe().field.safe().get_init_data(self.handle());
    }

    pub inline fn getDataRaw(
        self: Self,
        sdk: Verified(API.REFrameworkSDKData, .{ .field = .get_data_raw }),
        obj: ?*anyopaque,
        is_value_type: bool,
    ) ?*anyopaque {
        return sdk.safe().field.safe().get_data_raw(self.handle(), obj, is_value_type);
    }

    pub inline fn getIndex(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .field = .get_index })) u32 {
        return sdk.safe().field.safe().get_index(self.handle());
    }
};
