const std = @import("std");
const API = @import("API");
const Verified = @import("../verified.zig").Verified;
const Field = @import("Field.zig");
const ManagedObject = @import("ManagedObject.zig");
const Method = @import("Method.zig");
const Property = @import("Property.zig");
const TypeInfo = @import("TypeInfo.zig");

const re_error = @import("../re_error.zig");
const REFrameworkError = re_error.REFrameworkError;
const re_enums = @import("../re_enums.zig");
const CreateInstanceFlags = re_enums.CreateInstanceFlags;
const VmObjType = re_enums.VmObjType;

raw: API.REFrameworkTypeDefinitionHandle,

const TypeDefinition = @This();

pub inline fn handle(self: TypeDefinition) API.REFrameworkTypeDefinitionHandle {
    return self.raw;
}

pub fn getIndex(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_index })) u32 {
    return sdk.safe().type_definition.safe().get_index(self.handle());
}

pub fn getSize(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_size })) u32 {
    return sdk.safe().type_definition.safe().get_size(self.handle());
}

pub fn getValueTypeSize(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_valuetype_size })) u32 {
    return sdk.safe().type_definition.safe().get_valuetype_size(self.handle());
}

pub fn getFqn(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_fqn })) u32 {
    return sdk.safe().type_definition.safe().get_fqn(self.handle());
}

pub fn getName(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_name })) ?[:0]const u8 {
    const value = sdk.safe().type_definition.safe().get_name(self.handle()) orelse return null;
    return std.mem.span(value);
}

pub fn getNamespace(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_namespace })) ?[:0]const u8 {
    const value = sdk.safe().type_definition.safe().get_namespace(self.handle()) orelse return null;
    return std.mem.span(value);
}

pub fn getFullName(
    self: TypeDefinition,
    sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_full_name }),
    out: []u8,
) REFrameworkError![]u8 {
    var out_len: c_uint = 0;
    const result = sdk.safe().type_definition.safe().get_full_name(
        self.handle(),
        out.ptr,
        @intCast(out.len),
        &out_len,
    );
    try re_error.mapResult(result);
    if (out_len > out.len) return error.OutTooSmall;
    return out[0..out_len];
}

pub fn getFullNameAlloc(
    self: TypeDefinition,
    sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_full_name }),
    allocator: std.mem.Allocator,
) (REFrameworkError || std.mem.Allocator.Error)![]u8 {
    var buf = try allocator.alloc(u8, 256);
    errdefer allocator.free(buf);

    while (true) {
        var out_len: c_uint = 0;
        const result = sdk.safe().type_definition.safe().get_full_name(
            self.handle(),
            buf.ptr,
            @intCast(buf.len),
            &out_len,
        );

        if (result == API.REFRAMEWORK_ERROR_OUT_TOO_SMALL or out_len > buf.len) {
            buf = try allocator.realloc(buf, @max(buf.len * 2, @as(usize, out_len)));
            continue;
        }

        try re_error.mapResult(result);
        return buf[0..out_len];
    }
}

pub fn hasFieldptrOffset(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .has_fieldptr_offset })) bool {
    return sdk.safe().type_definition.safe().has_fieldptr_offset(self.handle());
}

pub fn getFieldptrOffset(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_fieldptr_offset })) i32 {
    return sdk.safe().type_definition.safe().get_fieldptr_offset(self.handle());
}

pub fn getNumMethods(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_num_methods })) u32 {
    return sdk.safe().type_definition.safe().get_num_methods(self.handle());
}

pub fn getNumFields(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_num_fields })) u32 {
    return sdk.safe().type_definition.safe().get_num_fields(self.handle());
}

pub fn getNumProperties(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_num_properties })) u32 {
    return sdk.safe().type_definition.safe().get_num_properties(self.handle());
}

pub fn isDerivedFrom(
    self: TypeDefinition,
    sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .is_derived_from }),
    other: TypeDefinition,
) bool {
    return sdk.safe().type_definition.safe().is_derived_from(self.handle(), other.handle());
}

pub fn isDerivedFromByName(
    self: TypeDefinition,
    sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .is_derived_from_by_name }),
    name: [:0]const u8,
) bool {
    return sdk.safe().type_definition.safe().is_derived_from_by_name(self.handle(), name.ptr);
}

pub fn isValueType(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .is_valuetype })) bool {
    return sdk.safe().type_definition.safe().is_valuetype(self.handle());
}

pub fn isEnum(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .is_enum })) bool {
    return sdk.safe().type_definition.safe().is_enum(self.handle());
}

pub fn isByRef(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .is_by_ref })) bool {
    return sdk.safe().type_definition.safe().is_by_ref(self.handle());
}

pub fn isPointer(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .is_pointer })) bool {
    return sdk.safe().type_definition.safe().is_pointer(self.handle());
}

pub fn isPrimitive(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .is_primitive })) bool {
    return sdk.safe().type_definition.safe().is_primitive(self.handle());
}

pub fn getVmObjType(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_vm_obj_type })) VmObjType {
    const result = sdk.safe().type_definition.safe().get_vm_obj_type(self.handle());
    return .fromU32(@intCast(result));
}

pub fn findMethod(
    self: TypeDefinition,
    sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .find_method }),
    name: [:0]const u8,
) ?Method {
    const result = sdk.safe().type_definition.safe().find_method(self.handle(), name.ptr);
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub fn findField(
    self: TypeDefinition,
    sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .find_field }),
    name: [:0]const u8,
) ?Field {
    const result = sdk.safe().type_definition.safe().find_field(self.handle(), name.ptr);
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub fn findProperty(
    self: TypeDefinition,
    sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .find_property }),
    name: [:0]const u8,
) ?Property {
    const result = sdk.safe().type_definition.safe().find_property(self.handle(), name.ptr);
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub fn getMethods(
    self: TypeDefinition,
    sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_methods }),
    out: []Method,
) REFrameworkError![]Method {
    var out_count: c_uint = 0;
    const result = sdk.safe().type_definition.safe().get_methods(
        self.handle(),
        @ptrCast(out.ptr),
        @intCast(out.len * @sizeOf(API.REFrameworkMethodHandle)),
        &out_count,
    );
    try re_error.mapResult(result);
    if (out_count > out.len) return error.OutTooSmall;
    return out[0..out_count];
}

pub fn getFields(
    self: TypeDefinition,
    sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_fields }),
    out: []Field,
) REFrameworkError![]Field {
    var out_count: c_uint = 0;
    const result = sdk.safe().type_definition.safe().get_fields(
        self.handle(),
        @ptrCast(out.ptr),
        @intCast(out.len * @sizeOf(API.REFrameworkFieldHandle)),
        &out_count,
    );
    try re_error.mapResult(result);
    if (out_count > out.len) return error.OutTooSmall;
    return out[0..out_count];
}

pub fn getInstance(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_instance })) ?*anyopaque {
    return sdk.safe().type_definition.safe().get_instance(self.handle());
}

pub fn createInstanceDeprecated(
    self: TypeDefinition,
    sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .create_instance_deprecated }),
) ?*anyopaque {
    return sdk.safe().type_definition.safe().create_instance_deprecated(self.handle());
}

pub fn createInstance(
    self: TypeDefinition,
    sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .create_instance }),
    flags: CreateInstanceFlags,
) ?ManagedObject {
    const result = sdk.safe().type_definition.safe().create_instance(self.handle(), @intFromEnum(flags));
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub fn getParentType(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_parent_type })) ?TypeDefinition {
    const result = sdk.safe().type_definition.safe().get_parent_type(self.handle());
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub fn getDeclaringType(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_declaring_type })) ?TypeDefinition {
    const result = sdk.safe().type_definition.safe().get_declaring_type(self.handle());
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub fn getUnderlyingType(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_underlying_type })) ?TypeDefinition {
    const result = sdk.safe().type_definition.safe().get_underlying_type(self.handle());
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub fn getTypeInfo(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_type_info })) ?TypeInfo {
    const result = sdk.safe().type_definition.safe().get_type_info(self.handle());
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub fn getRuntimeType(self: TypeDefinition, sdk: Verified(API.REFrameworkSDKData, .{ .type_definition = .get_runtime_type })) ?ManagedObject {
    const result = sdk.safe().type_definition.safe().get_runtime_type(self.handle());
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

comptime {
    std.debug.assert(@sizeOf(@This()) == @sizeOf(API.REFrameworkTypeDefinitionHandle));
    std.debug.assert(@alignOf(@This()) == @alignOf(API.REFrameworkTypeDefinitionHandle));
}
