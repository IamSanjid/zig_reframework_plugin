const API = @import("API");
const Verified = @import("../verified.zig").Verified;
const Field = @import("field.zig").Field;
const Method = @import("method.zig").Method;
const Module = @import("module.zig").Module;
const Property = @import("property.zig").Property;
const TypeDefinition = @import("type_definition.zig").TypeDefinition;

pub const Tdb = extern struct {
    raw: API.REFrameworkTDBHandle,

    const Self = @This();

    pub inline fn handle(self: Self) API.REFrameworkTDBHandle {
        return self.raw;
    }

    pub inline fn getNumModules(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .tdb = .get_num_modules })) u32 {
        return sdk.safe().tdb.safe().get_num_modules(self.handle());
    }

    pub inline fn getNumTypes(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .tdb = .get_num_types })) u32 {
        return sdk.safe().tdb.safe().get_num_types(self.handle());
    }

    pub inline fn getNumMethods(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .tdb = .get_num_methods })) u32 {
        return sdk.safe().tdb.safe().get_num_methods(self.handle());
    }

    pub inline fn getNumFields(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .tdb = .get_num_fields })) u32 {
        return sdk.safe().tdb.safe().get_num_fields(self.handle());
    }

    pub inline fn getNumProperties(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .tdb = .get_num_properties })) u32 {
        return sdk.safe().tdb.safe().get_num_properties(self.handle());
    }

    pub inline fn getType(
        self: Self,
        sdk: Verified(API.REFrameworkSDKData, .{ .tdb = .get_type }),
        index: u32,
    ) ?TypeDefinition {
        const result = sdk.safe().tdb.safe().get_type(self.handle(), index);
        return if (result) |value| .{ .raw = @ptrCast(value) } else null;
    }

    pub inline fn findType(
        self: Self,
        sdk: Verified(API.REFrameworkSDKData, .{ .tdb = .find_type }),
        name: [:0]const u8,
    ) ?TypeDefinition {
        const result = sdk.safe().tdb.safe().find_type(self.handle(), name.ptr);
        return if (result) |value| .{ .raw = @ptrCast(value) } else null;
    }

    pub inline fn findTypeByFqn(
        self: Self,
        sdk: Verified(API.REFrameworkSDKData, .{ .tdb = .find_type_by_fqn }),
        fqn: u32,
    ) ?TypeDefinition {
        const result = sdk.safe().tdb.safe().find_type_by_fqn(self.handle(), fqn);
        return if (result) |value| .{ .raw = @ptrCast(value) } else null;
    }

    pub inline fn getMethod(
        self: Self,
        sdk: Verified(API.REFrameworkSDKData, .{ .tdb = .get_method }),
        index: u32,
    ) ?Method {
        const result = sdk.safe().tdb.safe().get_method(self.handle(), index);
        return if (result) |value| .{ .raw = @ptrCast(value) } else null;
    }

    pub inline fn findMethod(
        self: Self,
        sdk: Verified(API.REFrameworkSDKData, .{ .tdb = .find_method }),
        type_name: [:0]const u8,
        method_name: [:0]const u8,
    ) ?Method {
        const result = sdk.safe().tdb.safe().find_method(self.handle(), type_name.ptr, method_name.ptr);
        return if (result) |value| .{ .raw = @ptrCast(value) } else null;
    }

    pub inline fn getField(
        self: Self,
        sdk: Verified(API.REFrameworkSDKData, .{ .tdb = .get_field }),
        index: u32,
    ) ?Field {
        const result = sdk.safe().tdb.safe().get_field(self.handle(), index);
        return if (result) |value| .{ .raw = @ptrCast(value) } else null;
    }

    pub inline fn findField(
        self: Self,
        sdk: Verified(API.REFrameworkSDKData, .{ .tdb = .find_field }),
        type_name: [:0]const u8,
        field_name: [:0]const u8,
    ) ?Field {
        const result = sdk.safe().tdb.safe().find_field(self.handle(), type_name.ptr, field_name.ptr);
        return if (result) |value| .{ .raw = @ptrCast(value) } else null;
    }

    pub inline fn getProperty(
        self: Self,
        sdk: Verified(API.REFrameworkSDKData, .{ .tdb = .get_property }),
        index: u32,
    ) ?Property {
        const result = sdk.safe().tdb.safe().get_property(self.handle(), index);
        return if (result) |value| .{ .raw = @ptrCast(value) } else null;
    }

    pub inline fn getModule(
        self: Self,
        sdk: Verified(API.REFrameworkSDKData, .{ .tdb = .get_module }),
        index: u32,
    ) ?Module {
        const result = sdk.safe().tdb.safe().get_module(self.handle(), index);
        return if (result) |value| .{ .raw = @ptrCast(value) } else null;
    }
};
