const std = @import("std");

pub inline fn RootType(T: type) type {
    const info = @typeInfo(T);
    switch (info) {
        .optional => |o| {
            return RootType(o.child);
        },
        .pointer => |p| {
            return RootType(p.child);
        },
        .array => |a| {
            return RootType(a.child);
        },
        else => {
            return T;
        },
    }
}

pub inline fn isTuple(T: type) bool {
    const info = @typeInfo(T);
    return info == .@"struct" and info.@"struct".is_tuple;
}

pub inline fn isPureStruct(T: type) bool {
    const info = @typeInfo(T);
    return info == .@"struct" and !info.@"struct".is_tuple;
}

pub inline fn intendedFieldName(comptime a: anytype, field: std.builtin.Type.StructField) []const u8 {
    if (isTuple(@TypeOf(a))) {
        return @tagName(@field(a, field.name));
    } else {
        return field.name;
    }
}

pub const StructFieldWithIntendedName = struct {
    intended_name: []const u8,
    orig_name: []const u8,
    type: type,
    default_value_ptr: ?*const anyopaque = null,
};

/// For tuple structs which contains only enum literals, the intended name
/// is the tag name of that enum literal.
pub inline fn fieldsWithIntendedName(comptime value: anytype) [std.meta.fields(@TypeOf(value)).len]StructFieldWithIntendedName {
    const ValueT = @TypeOf(value);
    const orig_fields = @typeInfo(ValueT).@"struct".fields;
    var fields: [orig_fields.len]StructFieldWithIntendedName = undefined;
    for (orig_fields, 0..) |field, i| {
        fields[i].intended_name = intendedFieldName(value, field);
        fields[i].orig_name = field.name;
        fields[i].type = field.type;
        fields[i].default_value_ptr = field.default_value_ptr;
    }
    return fields;
}

pub fn fieldIndexWithIntendedName(comptime value: anytype, comptime name: []const u8) ?comptime_int {
    inline for (fieldsWithIntendedName(value), 0..) |field, i| {
        if (std.mem.eql(u8, field.intended_name, name))
            return i;
    }
    return null;
}
