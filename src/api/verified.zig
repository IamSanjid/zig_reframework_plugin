const std = @import("std");
const type_utils = @import("../type_utils.zig");
const spec = @import("spec.zig");

const StructFieldWithIntendedName = type_utils.StructFieldWithIntendedName;
const isTuple = type_utils.isTuple;
const isPureStruct = type_utils.isPureStruct;
const fieldsWithIntendedName = type_utils.fieldsWithIntendedName;
const fieldIndexWithIntendedName = type_utils.fieldIndexWithIntendedName;

inline fn require(fn_opt: anytype, err: anyerror) !void {
    if (fn_opt == null) return err;
}

inline fn contains(comptime xs: []const @EnumLiteral(), comptime needle: @EnumLiteral()) bool {
    inline for (xs) |x| if (x == needle) return true;
    return false;
}

inline fn isVerified(T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct" or info.@"struct".is_tuple) {
        return false;
    }

    if (!@hasDecl(T, "SafeT") or !@hasDecl(T, "safe") or !@hasDecl(T, "safeFromOther")) {
        return false;
    }
    return true;
}

inline fn flattenFieldMetadata(field: std.builtin.Type.StructField) struct {
    type,
    std.builtin.Type.StructField.Attributes,
} {
    const info = @typeInfo(field.type);

    if (info == .optional) {
        return .{
            info.optional.child,
            .{
                .@"comptime" = false,
                .@"align" = null,
                .default_value_ptr = null,
            },
        };
    } else if (info == .pointer and info.pointer.size == .c) {
        return .{
            if (info.pointer.is_const) *const info.pointer.child else *info.pointer.child,
            .{
                .@"comptime" = false,
                .@"align" = null,
                .default_value_ptr = null,
            },
        };
    } else {
        return .{
            field.type,
            .{
                .@"comptime" = field.is_comptime,
                .@"align" = null,
                .default_value_ptr = field.default_value_ptr,
            },
        };
    }
}

fn SafeAll(T: type) type {
    const RootType = type_utils.RootType(T);
    const fields = std.meta.fields(RootType);
    var field_names: [fields.len][]const u8 = undefined;
    var field_types: [field_names.len]type = undefined;
    var field_attrs: [field_names.len]std.builtin.Type.StructField.Attributes = undefined;

    inline for (fields, 0..) |field, i| {
        field_names[i] = field.name;
        field_types[i], field_attrs[i] = flattenFieldMetadata(field);
    }

    return @Struct(
        .auto,
        null,
        &field_names,
        &field_types,
        &field_attrs,
    );
}

fn SafeMany(T: type, required_fields: anytype) type {
    const RootType = type_utils.RootType(T);
    const ReqFieldsT = @TypeOf(required_fields);
    const fields = @typeInfo(ReqFieldsT).@"struct".fields;

    var field_names: [fields.len][]const u8 = undefined;
    var field_types: [field_names.len]type = undefined;
    var field_attrs: [field_names.len]std.builtin.Type.StructField.Attributes = undefined;

    inline for (fields, 0..) |tuple_field, i| {
        const required_field = @field(required_fields, tuple_field.name);
        const required_field_name = @tagName(required_field);
        if (!@hasField(RootType, required_field_name)) {
            @compileError("There is no field called '" ++ required_field_name ++ "' in type '" ++ @typeName(RootType) ++ "'");
        }

        const field = std.meta.fieldInfo(RootType, required_field);
        field_names[i] = field.name;
        field_types[i], field_attrs[i] = flattenFieldMetadata(field);
    }

    return @Struct(
        .auto,
        null,
        &field_names,
        &field_types,
        &field_attrs,
    );
}

fn Safe(T: type, comptime required_fields: anytype) type {
    const ReqFieldsT = @TypeOf(required_fields);
    if (ReqFieldsT == @EnumLiteral()) {
        if (required_fields == .all) return SafeAll(T);
        if (required_fields == .all_recursive) return SafeAllRecursive(T);
        return SafeMany(T, .{required_fields});
    } else {
        if (isTuple(ReqFieldsT)) {
            return SafeMany(T, required_fields);
        }

        if (!isPureStruct(ReqFieldsT)) {
            @compileError("'required_fields' needs to be either a tuple or a struct");
        }

        const RootType = type_utils.RootType(T);

        const required_fields_metadata = @typeInfo(ReqFieldsT).@"struct".fields;

        const fields = std.meta.fields(RootType);

        var field_names: [required_fields_metadata.len][]const u8 = undefined;
        var field_types: [required_fields_metadata.len]type = undefined;
        var field_attrs: [required_fields_metadata.len]std.builtin.Type.StructField.Attributes = undefined;

        inline for (required_fields_metadata, 0..) |required_field_metadata, i| {
            const field_name = required_field_metadata.name;

            const field_index = std.meta.fieldIndex(RootType, field_name) orelse
                @compileError("There is no field called '" ++ field_name ++ "' in type '" ++ @typeName(RootType) ++ "'");

            const field = fields[field_index];

            field_names[i] = field_name;

            const is_nested_verified = comptime blk: {
                if (required_field_metadata.type == @EnumLiteral() or isTuple(required_field_metadata.type)) {
                    break :blk true;
                }

                if (isPureStruct(required_field_metadata.type) and std.meta.fields(required_field_metadata.type).len > 0) {
                    break :blk true;
                }

                break :blk false;
            };

            if (is_nested_verified) {
                field_types[i] = Verified(type_utils.RootType(field.type), @field(required_fields, field_name));
                field_attrs[i] = .{
                    .@"comptime" = false,
                    .@"align" = null,
                    .default_value_ptr = null,
                };
            } else {
                field_types[i], field_attrs[i] = flattenFieldMetadata(field);
            }
        }

        return @Struct(
            .auto,
            null,
            &field_names,
            &field_types,
            &field_attrs,
        );
    }
}

fn SafeAllRecursive(T: type) type {
    const RootType = type_utils.RootType(T);
    const fields = std.meta.fields(RootType);
    var field_names: [fields.len][]const u8 = undefined;
    var field_types: [field_names.len]type = undefined;
    var field_attrs: [field_names.len]std.builtin.Type.StructField.Attributes = undefined;

    inline for (fields, 0..) |field, i| {
        const info = @typeInfo(field.type);
        field_names[i] = field.name;

        if (info == .optional or (info == .pointer and info.pointer.size == .c)) {
            field_types = Verified(type_utils.RootType(field.type), .all_recursive);
            field_attrs[i] = .{
                .@"comptime" = false,
                .@"align" = null,
                .default_value_ptr = null,
            };
        } else {
            field_types[i] = field.type;
            field_attrs[i] = .{
                .@"comptime" = field.is_comptime,
                .@"align" = null,
                .default_value_ptr = field.default_value_ptr,
            };
        }
    }

    return @Struct(
        .auto,
        null,
        &field_names,
        &field_types,
        &field_attrs,
    );
}

fn ComptimeCheckVerifiedCast(From: type, To: type) void {
    // TODO: Find a logical quota instead of this arbitary value.
    @setEvalBranchQuota(2000000);
    const FromSafeT = From.SafeT;
    const ToSafeT = To.SafeT;

    const from_fields = std.meta.fields(FromSafeT);
    inline for (std.meta.fields(ToSafeT)) |to_field| {
        const from_field_index = std.meta.fieldIndex(FromSafeT, to_field.name) orelse
            @compileError("'" ++ @typeName(From) ++ "' type doesn't verify '" ++ to_field.name ++ "', which is needed by '" ++ @typeName(To) ++ "'");

        const from_field = from_fields[from_field_index];
        if (isVerified(from_field.type) and isVerified(to_field.type)) {
            ComptimeCheckVerifiedCast(from_field.type, to_field.type);
        } else if (to_field.type != from_field.type) {
            @compileError("The type of '" ++ to_field.name ++ "' is expected: " ++ @typeName(to_field.type) ++ " but other type is " ++ @typeName(from_field.type));
        }
    }
}

pub fn Verified(T: type, comptime required_fields: anytype) type {
    return struct {
        native: *const T,
        // since the overall design is to pass Verified all over the place,
        // an extra userdata field might open more possibilities, speciallly for
        // interoperability.
        userdata: ?*anyopaque,

        pub const SafeT = Safe(T, required_fields);

        const Self = @This();

        /// `native` can be one of: *T, *const T, [*c]T, [*c]const T, ?*T, ?*const T
        pub fn init(native: anytype) !Self {
            const NativeT = @TypeOf(native);
            const native_t_info = @typeInfo(NativeT);
            switch (native_t_info) {
                .optional => |o| {
                    const child_t_info = @typeInfo(o.child);
                    if (child_t_info != .pointer or child_t_info.pointer.child != T) {
                        @compileError("The 'native' type needs to be a optional pointer or a c-style pointer to '" ++ @typeName(T) ++ "'");
                    }
                    if (native == null) return error.Null;
                    try check(@ptrCast(native));
                    return .{
                        .native = @ptrCast(native),
                        .userdata = null,
                    };
                },
                .pointer => |p| {
                    if (p.child != T) {
                        @compileError("The 'native' type needs to be a pointer to '" ++ @typeName(T) ++ "'");
                    }
                    if (p.size == .c and native == null) return error.Null;
                    try check(@ptrCast(native));
                    return .{
                        .native = native,
                        .userdata = null,
                    };
                },
                else => @compileError("The 'native' type needs to be either a pointer or a optional pointer or a c-style pointer to '" ++ @typeName(T) ++ "'"),
            }
        }

        pub fn initWith(native: anytype, userdata: ?*anyopaque) !Self {
            var instance = init(native);
            instance.userdata = userdata;
            return instance;
        }

        pub fn fromOther(other_varified: anytype) Self {
            const Other = @TypeOf(other_varified);
            if (!isVerified(Other)) {
                @compileError("Expected a Verified type but found: '" ++ @typeName(Other) ++ "'");
            }
            ComptimeCheckVerifiedCast(Other, Self);

            return .{
                .native = other_varified.native,
                .userdata = other_varified.userdata,
            };
        }

        pub const fo = fromOther;

        pub fn safe(self: Self) SafeT {
            var safe_instance: SafeT = undefined;

            const fields = std.meta.fields(SafeT);
            inline for (fields) |field| {
                const native_field = @field(self.native, field.name);

                const SafeFieldT = field.type;
                if (isVerified(SafeFieldT)) {
                    @field(safe_instance, field.name) = SafeFieldT.init(native_field) catch unreachable;
                } else {
                    const info = @typeInfo(@TypeOf(native_field));
                    if (info == .optional or (info == .pointer and info.pointer.size == .c)) {
                        @field(safe_instance, field.name) = native_field orelse unreachable;
                    } else {
                        @field(safe_instance, field.name) = native_field;
                    }
                }
            }

            return safe_instance;
        }

        /// Comptime safety: `other_safe` must have all the required fields of the `SafeT`
        pub fn safeFromOther(other_safe: anytype) SafeT {
            var safe_instance: SafeT = undefined;

            const fields = std.meta.fields(SafeT);
            inline for (fields) |field| {
                if (!@hasField(other_safe, field.name)) {
                    @compileError("'" ++ @typeName(@TypeOf(other_safe)) ++ "' type doesn't have '" ++ field.name ++ "', which is required.");
                }

                if (isVerified(field.type)) {
                    const other_field = @field(other_safe, field.name);
                    const info = @typeInfo(@TypeOf(other_field));

                    if (info == .optional or info == .pointer) {
                        const VerifiedFieldT = field.type;
                        @field(safe_instance, field.name) = VerifiedFieldT.init(other_field) catch unreachable;
                    } else {
                        @field(safe_instance, field.name) = @field(other_safe, field.name);
                    }
                } else {
                    @field(safe_instance, field.name) = @field(other_safe, field.name);
                }
            }

            return safe_instance;
        }

        pub inline fn Extend(comptime more_required_fields: anytype) type {
            return Verified(T, spec.extend(required_fields, more_required_fields));
        }

        fn check(native: *const T) !void {
            const fields = std.meta.fields(SafeT);
            inline for (fields) |safe_field| {
                const field = @field(native, safe_field.name);

                if (isVerified(safe_field.type)) {
                    const VerifiedFieldT = safe_field.type;
                    _ = try VerifiedFieldT.init(field);
                } else {
                    const info = @typeInfo(@TypeOf(field));
                    if (info == .optional or (info == .pointer and info.pointer.size == .c)) {
                        try require(field, error.MissingField);
                    }
                }
            }
        }
    };
}
