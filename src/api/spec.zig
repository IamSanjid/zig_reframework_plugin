const std = @import("std");
const type_utils = @import("type_utils.zig");

const StructFieldWithIntendedName = type_utils.StructFieldWithIntendedName;
const isTuple = type_utils.isTuple;
const fieldsWithIntendedName = type_utils.fieldsWithIntendedName;
const fieldIndexWithIntendedName = type_utils.fieldIndexWithIntendedName;

fn ComptimeMerge(comptime a: anytype, comptime b: anytype) type {
    const a_struct = if (@TypeOf(a) == @EnumLiteral()) .{a} else a;
    const b_struct = if (@TypeOf(b) == @EnumLiteral()) .{b} else b;

    const A = @TypeOf(a_struct);
    const B = @TypeOf(b_struct);

    const a_fields = fieldsWithIntendedName(a_struct);
    const b_fields = fieldsWithIntendedName(b_struct);

    var field_names: [a_fields.len + b_fields.len][]const u8 = undefined;
    var field_types: [field_names.len]type = undefined;
    var field_attrs: [field_names.len]std.builtin.Type.StructField.Attributes = undefined;

    var field_index = 0;

    const enum_to_struct_default_value: struct {} = .{};
    const constructField = struct {
        inline fn f(OwnerT: type, a_field: StructFieldWithIntendedName) struct {
            type,
            std.builtin.Type.StructField.Attributes,
        } {
            if (isTuple(OwnerT)) {
                return .{
                    @TypeOf(enum_to_struct_default_value),
                    .{
                        .@"comptime" = true,
                        .default_value_ptr = &enum_to_struct_default_value,
                    },
                };
            } else {
                return .{
                    a_field.type,
                    .{
                        .@"comptime" = true,
                        .default_value_ptr = a_field.default_value_ptr,
                    },
                };
            }
        }
    }.f;

    inline for (a_fields) |a_field| {
        field_names[field_index] = a_field.intended_name;
        if (fieldIndexWithIntendedName(b_struct, a_field.intended_name) != null) {
            @compileError("Cannot merge spec a and spec b, both has '" ++ a_field.intended_name ++ "' field, use `extend` if you want to overwrite or extend.");
        } else {
            // unique a fields
            field_types[field_index], field_attrs[field_index] = constructField(A, a_field);
        }
        field_index += 1;
    }

    // unique b fields
    inline for (b_fields) |b_field| {
        field_names[field_index] = b_field.intended_name;
        field_types[field_index], field_attrs[field_index] = constructField(B, b_field);
        field_index += 1;
    }

    const Out = @Struct(
        .auto,
        null,
        field_names[0..field_index],
        field_types[0..field_index],
        field_attrs[0..field_index],
    );

    return struct {
        const T = Out;
        pub fn init() T {
            var out: T = undefined;

            // unique a fields
            inline for (a_fields) |a_field| {
                if (isTuple(A)) {
                    @field(out, a_field.intended_name) = enum_to_struct_default_value;
                } else {
                    @field(out, a_field.intended_name) = @field(a_struct, a_field.orig_name);
                }
            }

            // unique b fields
            inline for (b_fields) |b_field| {
                if (isTuple(B)) {
                    @field(out, b_field.intended_name) = enum_to_struct_default_value;
                } else {
                    @field(out, b_field.intended_name) = @field(b_struct, b_field.orig_name);
                }
            }

            return out;
        }
    };
}

inline fn mergeComptime(comptime a: anytype, comptime b: anytype) ComptimeMerge(a, b).T {
    return ComptimeMerge(a, b).init();
}

test "mergeComptime" {
    {
        const a = .{.a};
        const b = .{.b};
        const merged = comptime extendComptime(a, b);
        try std.testing.expect(comptime @TypeOf(merged.a) == @TypeOf(merged.b));
    }

    {
        const a = .{.a};
        const b = .{ .b = .{.b_is_struct} };
        const merged = comptime extendComptime(a, b);
        try std.testing.expect(comptime merged.b.@"0" == .b_is_struct and @hasField(@TypeOf(merged), "a"));
    }

    {
        const a = .{};
        const b = .{ .extended = .something };
        const merged = comptime extendComptime(a, b);
        try std.testing.expect(comptime @hasField(@TypeOf(merged), "extended"));
        try std.testing.expect(comptime merged.extended == .something);
    }
}

/// Supports .{ .foo = .{ .extend = .{} } }
fn ComptimeExtend(comptime a: anytype, comptime b: anytype) type {
    const a_struct = if (@TypeOf(a) == @EnumLiteral()) .{a} else a;
    const b_struct = if (@TypeOf(b) == @EnumLiteral()) .{b} else b;

    const A = @TypeOf(a_struct);
    const B = @TypeOf(b_struct);

    const a_fields = fieldsWithIntendedName(a_struct);
    const b_fields = fieldsWithIntendedName(b_struct);

    var field_names: [a_fields.len + b_fields.len][]const u8 = undefined;
    var field_types: [field_names.len]type = undefined;
    var field_attrs: [field_names.len]std.builtin.Type.StructField.Attributes = undefined;

    var field_index = 0;

    const enum_to_struct_default_value: struct {} = .{};
    const constructField = struct {
        inline fn f(OwnerT: type, a_field: StructFieldWithIntendedName) struct {
            type,
            std.builtin.Type.StructField.Attributes,
        } {
            if (isTuple(OwnerT)) {
                return .{
                    @TypeOf(enum_to_struct_default_value),
                    .{
                        .@"comptime" = true,
                        .default_value_ptr = &enum_to_struct_default_value,
                    },
                };
            } else {
                return .{
                    a_field.type,
                    .{
                        .@"comptime" = true,
                        .default_value_ptr = a_field.default_value_ptr,
                    },
                };
            }
        }
    }.f;

    inline for (a_fields) |a_field| {
        field_names[field_index] = a_field.intended_name;
        if (fieldIndexWithIntendedName(b_struct, a_field.intended_name)) |b_field_index| {
            const b_field = b_fields[b_field_index];
            // support .extend
            const extend_field = @field(b_struct, b_field.orig_name);
            const ExtendFieldT = @TypeOf(extend_field);
            if (ExtendFieldT != @EnumLiteral() and @hasField(ExtendFieldT, "extend")) {
                const ExtendT = ComptimeExtend(@field(a_struct, a_field.orig_name), extend_field.extend);
                field_types[field_index] = ExtendT.T;
                field_attrs[field_index] = .{
                    .@"comptime" = true,
                    .default_value_ptr = &ExtendT.init(),
                };
            } else {
                // overwrite with b
                field_types[field_index], field_attrs[field_index] = constructField(B, b_field);
            }
        } else {
            // unique a fields
            field_types[field_index], field_attrs[field_index] = constructField(A, a_field);
        }
        field_index += 1;
    }

    // unique b fields
    inline for (b_fields) |b_field| {
        if (fieldIndexWithIntendedName(a_struct, b_field.intended_name) == null) {
            field_names[field_index] = b_field.intended_name;
            field_types[field_index], field_attrs[field_index] = constructField(B, b_field);
            field_index += 1;
        }
    }

    const Out = @Struct(
        .auto,
        null,
        field_names[0..field_index],
        field_types[0..field_index],
        field_attrs[0..field_index],
    );

    return struct {
        const T = Out;
        pub fn init() T {
            var out: T = undefined;

            inline for (a_fields) |a_field| {
                if (fieldIndexWithIntendedName(b_struct, a_field.intended_name)) |b_field_index| {
                    const b_field = b_fields[b_field_index];
                    // support .extend
                    const extend_field = @field(b_struct, b_field.orig_name);
                    const ExtendFieldT = @TypeOf(extend_field);
                    if (ExtendFieldT != @EnumLiteral() and @hasField(ExtendFieldT, "extend")) {
                        const ExtendT = ComptimeExtend(@field(a_struct, a_field.orig_name), extend_field.extend);
                        @field(out, a_field.intended_name) = ExtendT.init();
                    } else {
                        // overwrite with b
                        if (isTuple(B)) {
                            @field(out, b_field.intended_name) = enum_to_struct_default_value;
                        } else {
                            @field(out, b_field.intended_name) = @field(b_struct, b_field.orig_name);
                        }
                    }
                } else {
                    // unique a fields
                    if (isTuple(A)) {
                        @field(out, a_field.intended_name) = enum_to_struct_default_value;
                    } else {
                        @field(out, a_field.intended_name) = @field(a_struct, a_field.orig_name);
                    }
                }
            }

            // unique b fields
            inline for (b_fields) |b_field| {
                if (fieldIndexWithIntendedName(a_struct, b_field.intended_name) == null) {
                    if (isTuple(B)) {
                        @field(out, b_field.intended_name) = enum_to_struct_default_value;
                    } else {
                        @field(out, b_field.intended_name) = @field(b_struct, b_field.orig_name);
                    }
                }
            }

            return out;
        }
    };
}

inline fn extendComptime(comptime a: anytype, comptime b: anytype) ComptimeExtend(a, b).T {
    return ComptimeExtend(a, b).init();
}

test "extendComptime" {
    {
        const a = .{.a};
        const b = .{.b};
        const merged = comptime extendComptime(a, b);
        try std.testing.expect(comptime @TypeOf(merged.a) == @TypeOf(merged.b));
    }

    {
        const a = .{.a};
        const b = .{ .a = .{.b_is_struct} };
        const merged = comptime extendComptime(a, b);
        try std.testing.expect(comptime merged.a.@"0" == .b_is_struct);
    }

    {
        const a = .{ .a = .{}, .b = .a_active };
        const b = .{ .b = .b_active };
        const merged = comptime extendComptime(a, b);
        try std.testing.expect(comptime merged.b == .b_active);
    }

    {
        const a = .{ .a = .{}, .b = .a_active };
        const b = .{ .b = .{ .extend = .b_active } };
        const merged = comptime extendComptime(a, b);
        try std.testing.expect(comptime @hasField(@TypeOf(merged), "a"));
        try std.testing.expect(comptime @TypeOf(merged.b.a_active) == @TypeOf(merged.b.b_active));
    }

    {
        const a = .{};
        const b = .{ .extended = .something };
        const merged = comptime extendComptime(a, b);
        try std.testing.expect(comptime @hasField(@TypeOf(merged), "extended"));
        try std.testing.expect(comptime merged.extended == .something);
    }
}

/// Simply merges spec a and spec b.
pub const merge = mergeComptime;
/// For non-unique keys overwrites spec a with spec b, also extends when specified
/// with .extend = .{ .. }. Otherwise same as `merge`.
pub const extend = extendComptime;
