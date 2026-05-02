const std = @import("std");
const api = @import("api.zig");
const type_utils = @import("type_utils.zig");

const m = @import("interop/metadata.zig");
pub const MethodMetadata = m.MethodMetadata;
pub const FieldMetadata = m.FieldMetadata;
pub const TypeDefMetadata = m.TypeDefMetadata;
pub const ManagedObjectMetadata = m.ManagedObjectMetadata;

const managed_type_cache = @import("interop/managed_type_cache.zig");
pub const ManagedTypeCache = managed_type_cache.ManagedTypeCache;
pub const Scope = @import("interop/Scope.zig");

const resolved_type = @import("interop/resolved_type.zig");
pub const ResolvedType = resolved_type.ResolvedType;

const misc = @import("interop/misc.zig");
const isSafeMode = misc.isSafeMode;

const type_builder = @import("interop/type_builder.zig");
pub const ManagedObjectTypeBuilder = type_builder.ManagedObjectTypeBuilder;
pub const ManagedObjectSelf = type_builder.ManagedObjectSelf;
const isManagedInterop = type_builder.isManagedInterop;

const native = std.builtin.Endian.native;

const sdk_interop_specs = .{
    .functions = api.specs.merge(
        .{ .create_managed_string, .create_managed_string_normal },
        Scope.functions_sepcs,
    ),
    .managed_object = Scope.managed_object_specs,
    .method = Scope.method_specs,
    .field = api.specs.merge(Scope.field_specs, .get_offset_from_base),
    .type_definition = .all,
    .tdb = resolved_type.tdb_specs,
};

pub const InteropSdk = api.VerifiedSdk(sdk_interop_specs);

const managed_object_runtime_size = api.sdk.ManagedObject.runtime_size;

pub const ValueType = struct {
    data: []align(@alignOf(*anyopaque)) u8,
    type_def: api.sdk.TypeDefinition,

    const Self = @This();

    pub fn init(arena: std.mem.Allocator, sdk: InteropSdk, data: *?*anyopaque, type_def: api.sdk.TypeDefinition) !Self {
        @setRuntimeSafety(false);

        const data_p: [*]u8 = @ptrCast(@alignCast(data));
        const size = type_def.getValueTypeSize(.fo(sdk));
        const buf = try arena.alignedAlloc(u8, .of(usize), managed_object_runtime_size + size);
        @memset(buf, 0);

        @memcpy(buf[managed_object_runtime_size..], data_p[0..size]);

        // REObject header: REObjectInfo* at offset 0x00
        @as(*api.sdk.TypeDefinition, @ptrCast(@alignCast(&buf[0x00]))).* = type_def;
        // REManagedObject: reference count at offset 0x08 (set high to prevent GC interference)
        @as(*u32, @ptrCast(@alignCast(&buf[@sizeOf(api.sdk.TypeDefinition)]))).* = 9999;

        return .{
            .data = buf,
            .type_def = type_def,
        };
    }

    pub inline fn unsafeManaged(self: Self) api.sdk.ManagedObject {
        @setRuntimeSafety(false);
        return .{ .raw = @ptrCast(@alignCast(&self.data[0])) };
    }

    pub inline fn valuePtr(self: Self) *anyopaque {
        return @ptrCast(@alignCast(&self.data[managed_object_runtime_size]));
    }

    pub inline fn call(
        self: Self,
        sig: [:0]const u8,
        comptime param_interops: anytype,
        comptime ret: anytype,
        scope: *Scope,
        sdk: api.VerifiedSdk(.{
            .method = sdk_interop_specs.method,
            .managed_object = sdk_interop_specs.managed_object,
            .type_definition = .all,
        }),
        args: anytype,
    ) !ret.type {
        const method_metadata = try scope.cache.getOrCacheMethodMetadata(.fo(sdk), self.type_def, sig);
        return try scope.invokeMethod(
            self.unsafeManaged().raw,
            method_metadata,
            param_interops,
            ret,
            false,
            .fo(sdk),
            args,
        );
    }

    pub inline fn get(
        self: Self,
        field_name: [:0]const u8,
        comptime T: type,
        scope: *Scope,
        sdk: api.VerifiedSdk(.{
            .field = sdk_interop_specs.field,
            .managed_object = sdk_interop_specs.managed_object,
            .type_definition = .all,
        }),
    ) !T {
        return scope.getFieldFromTypeDef(
            self.valuePtr(),
            self.type_def,
            field_name,
            T,
            defaultToZigInterop(T),
            false,
            .fo(sdk),
        );
    }

    pub inline fn set(
        self: Self,
        field_name: [:0]const u8,
        scope: *Scope,
        sdk: api.VerifiedSdk(.{
            .field = sdk_interop_specs.field,
            .managed_object = sdk_interop_specs.managed_object,
            .type_definition = .all,
        }),
        value: anytype,
    ) !void {
        return scope.setFieldFromTypeDef(
            self.valuePtr(),
            self.type_def,
            field_name,
            defaultFromZigInterop,
            false,
            .fo(sdk),
            value,
        );
    }
};

pub const SystemStringView = struct {
    data: [:0]const u16,

    pub inline fn fromRaw(ptr: *anyopaque) SystemStringView {
        @setRuntimeSafety(false);
        const data: [*:0]const u16 = @ptrCast(@alignCast(ptr));
        return .{ .data = std.mem.span(data) };
    }
};

pub const SystemArrayEntries = struct {
    ptr: ?*anyopaque,
    len: u32,
    contained_type_def: api.sdk.TypeDefinition,

    pub inline fn unsafe(managed: api.sdk.ManagedObject, sdk: InteropSdk) SystemArrayEntries {
        @setRuntimeSafety(false);
        const ptr_usize: usize = @intFromPtr(managed.raw);
        const size_of_rearraybase = managed_object_runtime_size + 0x10;
        const contained_type_def_ptr: *api.sdk.TypeDefinition = @ptrFromInt(ptr_usize + managed_object_runtime_size);
        var contained_type_def = contained_type_def_ptr.*;
        // RE7?
        if (managed_object_runtime_size > 0x10 and contained_type_def.getVmObjType(.fo(sdk)) == .unknown) {
            const contained_type_def_ptr2: **api.sdk.TypeDefinition = @ptrFromInt(ptr_usize + managed_object_runtime_size);
            contained_type_def = contained_type_def_ptr2.*.*;
        }
        const len_ptr: *u32 = @ptrFromInt(ptr_usize + size_of_rearraybase - @sizeOf(u32));
        const ptr: ?*anyopaque = @ptrFromInt(ptr_usize + size_of_rearraybase);
        return .{
            .ptr = ptr,
            .len = len_ptr.*,
            .contained_type_def = contained_type_def,
        };
    }
};

inline fn systemStrPtr(
    type_def: api.sdk.TypeDefinition,
    managed: api.sdk.ManagedObject,
    sdk: InteropSdk,
) ?*anyopaque {
    @setRuntimeSafety(false);
    // https://github.com/praydog/REFramework/blob/c4b1314820d20255febf7834903e8cedb669b49c/csharp-api/REFrameworkNET/SystemString.cpp#L25
    const ptr: usize = @intFromPtr(managed.raw);
    if (type_def.findField(.fo(sdk), "_firstChar")) |field| {
        return @ptrFromInt(ptr + field.getOffsetFromBase(.fo(sdk)));
    }
    const field_offset: *usize = @ptrFromInt(ptr);
    const field_offset_ptr: *u32 = @ptrFromInt(field_offset.* - @sizeOf(*anyopaque));
    return @ptrFromInt(ptr + field_offset_ptr.* + 4);
}

pub const FromZigInterop = @TypeOf(defaultFromZigInterop);

pub fn ToZigInterop(comptime T: type) type {
    return @TypeOf(defaultToZigInterop(T));
}

// TODO: Implement more cases:
// https://github.com/praydog/REFramework/blob/ea66d322fbe2ebb7e2efd8fd6aa6b06779da6f76/src/mods/bindings/Sdk.cpp#L1086
pub fn defaultFromZigInterop(
    sdk_ptr: *const anyopaque,
    scope: *Scope,
    to_type_def: api.sdk.TypeDefinition,
    arg: anytype,
    out: *?*anyopaque,
) anyerror!void {
    @setRuntimeSafety(false);
    const sdk: *const InteropSdk = @ptrCast(@alignCast(sdk_ptr));

    const ArgT = @TypeOf(arg);
    switch (ArgT) {
        [:0]const u8, [:0]u8 => {
            const managed_string = api.sdk.createManagedStringNormal(.fo(sdk), arg) orelse return error.FailedToCreateString;
            out.* = @ptrCast(managed_string.raw);
            return;
        },
        [*:0]const u8 => {
            const managed_string = api.sdk.createManagedStringNormal(.fo(sdk), std.mem.span(arg)) orelse return error.FailedToCreateString;
            out.* = @ptrCast(managed_string.raw);
            return;
        },
        [:0]const u16, [:0]u16 => {
            const managed_string = api.sdk.createManagedString(.fo(sdk), arg) orelse return error.FailedToCreateString;
            out.* = @ptrCast(managed_string.raw);
            return;
        },
        [*:0]const u16 => {
            const managed_string = api.sdk.createManagedString(.fo(sdk), std.mem.span(arg)) orelse return error.FailedToCreateString;
            out.* = @ptrCast(managed_string.raw);
            return;
        },
        @Vector(2, f32) => {},
        SystemStringView => {
            return defaultFromZigInterop(sdk_ptr, scope, to_type_def, arg.data, out);
        },
        ?api.sdk.ManagedObject => {
            if (arg) |v| {
                out.* = @ptrCast(v.raw);
            } else {
                out.* = null;
            }
            return;
        },
        api.sdk.ManagedObject => {
            out.* = @ptrCast(arg.raw);
            return;
        },
        ValueType => {
            // when we're inside of other process its hard to catch std.debug.assert.
            if (comptime isSafeMode()) {
                // For ValueTypes we need to match the type defs
                if (to_type_def.getVmObjType(.fo(sdk)) != .valtype) {
                    return error.ExpectedValueType;
                }
                if (to_type_def.raw != arg.type_def.raw) {
                    return error.ValueTypeDefMismatch;
                }
            }

            const b: [*]u8 = @ptrCast(out);
            @memcpy(b[0..arg.data.len], arg.data);
            return;
        },
        else => {
            if (comptime isManagedInterop(ArgT)) {
                out.* = @ptrCast(arg.managed.raw);
                return;
            }
        },
    }

    const arg_t_info = @typeInfo(ArgT);
    switch (arg_t_info) {
        .int => |int| {
            if (int.bits > @sizeOf(usize) * std.mem.byte_size_in_bits) {
                @compileError("Cannot interop '" ++ @typeName(ArgT) ++ "', it's too big.");
            }

            const b: [*]u8 = @ptrCast(out);
            std.mem.writeInt(ArgT, b[0..@sizeOf(ArgT)], arg, native);
            return;
        },
        .float => |float| {
            if (float.bits > @sizeOf(u64) * std.mem.byte_size_in_bits) {
                @compileError("Cannot interop '" ++ @typeName(ArgT) ++ "', it's too big.");
            }
            const b: [*]u8 = @ptrCast(out);

            if (float.bits >= 0 and float.bits <= 32) {
                std.mem.writeInt(u32, b[0..@sizeOf(u32)], @bitCast(arg), native);
            } else {
                std.mem.writeInt(u64, b[0..@sizeOf(u64)], @bitCast(arg), native);
            }
            return;
        },
        .bool => {
            const b: *u8 = @ptrCast(out);
            b.* = @intFromBool(arg);
            return;
        },
        .comptime_int => {
            const b: [*]u8 = @ptrCast(out);
            std.mem.writeInt(usize, b[0..@sizeOf(usize)], arg, native);
            return;
        },
        .comptime_float => {
            const b: [*]u8 = @ptrCast(out);
            std.mem.writeInt(u64, b[0..@sizeOf(u64)], @intFromFloat(arg), native);
            return;
        },
        .@"enum" => {
            // TODO: use the actual underlying type of the enum, `getUnderlyingType`
            const enum_val = if (@sizeOf(arg_t_info.@"enum".tag_type) < @sizeOf(c_int))
                @as(c_int, @intFromEnum(arg))
            else
                @intFromEnum(arg);
            return defaultFromZigInterop(sdk_ptr, scope, to_type_def, enum_val, out);
        },
        .@"struct" => {
            @compileError("Cannot interop zig struct");
        },
        .optional => |o| {
            if (@typeInfo(o.child) != .@"struct" and @typeInfo(o.child) != .pointer) {
                @compileError("Option struct and pointer types are the only supported optional types. Found: '" ++ @typeName(ArgT) ++ "'");
            }

            if (arg) |v| {
                try defaultFromZigInterop(sdk_ptr, scope, to_type_def, v, out);
            } else {
                out.* = null;
            }
            return;
        },
        .pointer => |p| {
            if (isManagedInterop(p.child)) {
                out.* = @ptrCast(arg.*.managed.raw);
            } else {
                out.* = @ptrCast(arg);
            }
            return;
        },
        .undefined => {
            out.* = null;
            return;
        },
        .null => {
            out.* = null;
            return;
        },
        else => {
            @compileError("Cannot interop type: '" ++ @typeName(ArgT) ++ "'");
        },
    }
}

// TODO: Implement more cases:
// https://github.com/praydog/REFramework/blob/ea66d322fbe2ebb7e2efd8fd6aa6b06779da6f76/src/mods/bindings/Sdk.cpp#L927
pub fn defaultToZigInterop(RetType: type) fn (*const anyopaque, *Scope, api.sdk.TypeDefinition, *?*anyopaque) anyerror!RetType {
    return struct {
        fn func(
            sdk_ptr: *const anyopaque,
            scope: *Scope,
            from_type_def: api.sdk.TypeDefinition,
            data: *?*anyopaque,
        ) anyerror!RetType {
            @setRuntimeSafety(false);
            // _ = from_type_def;
            if (RetType == void) return {};

            const sdk: *const InteropSdk = @ptrCast(@alignCast(sdk_ptr));

            switch (RetType) {
                []const u8, []u8 => {
                    @compileError("Please consider using SystemStringView type, and later convert it to u8 your own way.");
                },
                [:0]u16 => {
                    return (try defaultToZigInterop(SystemStringView)(sdk_ptr, scope, from_type_def, data)).data;
                },
                [*:0]u16 => {
                    return (try defaultToZigInterop(SystemStringView)(sdk_ptr, scope, from_type_def, data)).data.ptr;
                },
                @Vector(2, f32) => {
                    if (comptime isSafeMode()) {
                        const float2_type_name = "via.Float2";
                        const viaf2_type_name = "via.vec2";
                        const full_name = try from_type_def.getFullName(.fo(sdk), null);
                        if (!std.mem.eql(u8, float2_type_name, full_name) and !std.mem.eql(u8, viaf2_type_name, full_name)) {
                            return error.ExpectedFloat2Type;
                        }
                    }
                    return @as(*const [2]f32, @ptrCast(@alignCast(data))).*;
                },
                @Vector(3, f32) => {
                    if (comptime isSafeMode()) {
                        const float3_type_name = "via.Float3";
                        const viaf3_type_name = "via.vec3";
                        const full_name = try from_type_def.getFullName(.fo(sdk), null);
                        if (!std.mem.eql(u8, float3_type_name, full_name) and !std.mem.eql(u8, viaf3_type_name, full_name)) {
                            return error.ExpectedFloat3Type;
                        }
                    }
                    return @as(*const [3]f32, @ptrCast(@alignCast(data))).*;
                },
                @Vector(4, f32) => {
                    if (comptime isSafeMode()) {
                        const float4_type_name = "via.Float4";
                        const viaf4_type_name = "via.vec4";
                        const full_name = try from_type_def.getFullName(.fo(sdk), null);
                        if (!std.mem.eql(u8, float4_type_name, full_name) and !std.mem.eql(u8, viaf4_type_name, full_name)) {
                            return error.ExpectedFloat4Type;
                        }
                    }
                    return @as(*const [4]f32, @ptrCast(@alignCast(data))).*;
                },
                SystemStringView => {
                    if (comptime isSafeMode()) {
                        const system_string_type_name = "System.String";
                        var full_name_buf: [system_string_type_name.len]u8 = undefined;
                        const full_name = try from_type_def.getFullName(.fo(sdk), &full_name_buf);
                        if (!std.mem.eql(u8, system_string_type_name, full_name)) {
                            return error.ExpectedStringType;
                        }
                    }

                    const ptr: ?*anyopaque = data.*;
                    if (ptr == null) return error.ReturnedUnexpectedNull;
                    const managed_ret_val = api.sdk.ManagedObject{ .raw = @ptrCast(@alignCast(ptr)) };
                    return .fromRaw(systemStrPtr(
                        from_type_def,
                        managed_ret_val,
                        .fo(sdk),
                    ) orelse return error.FailedToGetStringData);
                },
                api.sdk.ManagedObject => {
                    if (comptime isSafeMode()) {
                        // for `valtypes` its required to use the special ValueType wrapper.
                        if (from_type_def.getVmObjType(.fo(sdk)) == .valtype) {
                            return error.ExpectedNonValueType;
                        }
                    }

                    const ptr: ?*anyopaque = data.*;
                    if (ptr == null) return error.ReturnedUnexpectedNull;
                    return .{ .raw = @ptrCast(@alignCast(ptr)) };
                },
                ValueType => {
                    if (comptime isSafeMode()) {
                        // for `valtypes` its required to use the special ValueType wrapper.
                        if (from_type_def.getVmObjType(.fo(sdk)) != .valtype) {
                            return error.ExpectedValueType;
                        }
                    }
                    return try ValueType.init(scope.arena.allocator(), sdk.*, data, from_type_def);
                },
                else => {},
            }

            const ret_t_info = @typeInfo(RetType);
            if (isManagedInterop(RetType)) {
                if (comptime isSafeMode()) {
                    // for `valtypes` its required to use the special ValueType wrapper.
                    if (from_type_def.getVmObjType(.fo(sdk)) == .valtype) {
                        return error.ExpectedNonValueType;
                    }
                }

                const ptr: ?*anyopaque = data.*;
                if (ptr == null) return error.ReturnedUnexpectedNull;
                const obj: api.sdk.ManagedObject = .{ .raw = @ptrCast(@alignCast(ptr)) };
                return try RetType.init(scope.cache, sdk.*, obj);
            } else switch (ret_t_info) {
                .int => {
                    const b: [*]const u8 = @ptrCast(data);
                    return std.mem.readInt(RetType, b[0..@sizeOf(RetType)], native);
                },
                .float => |float| {
                    const b: [*]const u8 = @ptrCast(data);
                    if (float.bits >= 0 and float.bits <= 32) {
                        return @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, b[0..@sizeOf(u32)], native))));
                    } else if (float.bits <= 64) {
                        return @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, b[0..@sizeOf(u64)], native))));
                    } else {
                        return @floatCast(@as(f128, @bitCast(std.mem.readInt(u128, b[0..@sizeOf(u128)], native))));
                    }
                },
                .bool => {
                    const b: [*]const u8 = @ptrCast(data);
                    return if (b[0] > 0) true else false;
                },
                .@"enum" => {
                    // TODO: use the actual underlying type of the enum, `getUnderlyingType`
                    const EnumUnderlyingT = if (@sizeOf(ret_t_info.@"enum".tag_type) < @sizeOf(c_int)) c_int else ret_t_info.@"enum".tag_type;
                    return @enumFromInt(try defaultToZigInterop(EnumUnderlyingT)(sdk_ptr, scope, from_type_def, data));
                },
                .optional => |o| {
                    if (@typeInfo(o.child) != .@"struct" and @typeInfo(o.child) != .pointer) {
                        @compileError("Option struct and pointer types are the only supported optional types for return values. Found: '" ++ @typeName(RetType) ++ "'");
                    }
                    const ptr: ?*anyopaque = data.*;
                    if (ptr == null) return null;

                    return try defaultToZigInterop(o.child)(sdk_ptr, scope, from_type_def, data);
                },
                .pointer => {
                    return @ptrCast(@alignCast(data.*));
                },
                else => {
                    @compileError("Cannot interop type: '" ++ @typeName(RetType) ++ "'");
                },
            }
        }
    }.func;
}

const MethodParam = struct {
    type_name: ?[:0]const u8 = null,
    type: type,
    comptime interop: FromZigInterop = defaultFromZigInterop,
};

fn MethodData(comptime method: anytype, comptime i: anytype) type {
    return struct {
        const Data = @TypeOf(method);
        fn get() Data {
            return method;
        }
        fn getIndex() @TypeOf(i) {
            return i;
        }
        fn RetType() type {
            if (@hasField(Data, "ret")) {
                return get().ret.type;
            } else {
                return void;
            }
        }
        fn getParam(comptime index: comptime_int) MethodParam {
            const param = @field(get().params, std.fmt.comptimePrint("{d}", .{index}));
            return .{
                .type_name = param.type_name,
                .type = param.type,
                .interop = if (@hasField(@TypeOf(param), "interop")) param.interop else defaultFromZigInterop,
            };
        }
        fn getParamsLen() comptime_int {
            return std.meta.fields(@TypeOf(get().params)).len;
        }
    };
}

fn buildMethodArgsImpl(
    sdk: *const anyopaque,
    scope: *Scope,
    method_metadata: *const MethodMetadata,
    args: anytype,
    comptime param_interops: [std.meta.fields(@TypeOf(args)).len]FromZigInterop,
) anyerror![std.meta.fields(@TypeOf(args)).len]?*anyopaque {
    @setRuntimeSafety(false);

    const args_len = std.meta.fields(@TypeOf(args)).len;
    var out: [args_len]?*anyopaque = undefined;

    inline for (0..args_len) |i| {
        const arg = @field(args, std.fmt.comptimePrint("{d}", .{i}));
        if (@TypeOf(arg) == ValueType) {
            out[i] = arg.valuePtr();
        } else {
            try param_interops[i](
                sdk,
                scope,
                method_metadata.param_type_defs[i],
                arg,
                &out[i],
            );
        }
    }

    return out;
}

pub inline fn buildMethodArgs(
    sdk: *const anyopaque,
    scope: *Scope,
    method_metadata: *const MethodMetadata,
    args: anytype,
    comptime param_interops: anytype,
) anyerror![std.meta.fields(@TypeOf(args)).len]?*anyopaque {
    const ParamInteropsT = @TypeOf(param_interops);
    const param_interops_len = comptime std.meta.fields(ParamInteropsT).len;
    const args_len = comptime std.meta.fields(@TypeOf(args)).len;
    if (param_interops_len > 0 and param_interops_len != args_len) {
        @compileError("param_interops len has to match the args length or has to be 0 or .{}");
    }

    comptime var param_interop_fns: [args_len]FromZigInterop = undefined;
    if (param_interops_len > 0) {
        inline for (0..args_len) |i| {
            const arg_index_str = std.fmt.comptimePrint("{d}", .{i});
            param_interop_fns[i] = @field(param_interops, arg_index_str);
        }
    } else {
        inline for (0..args_len) |i| {
            param_interop_fns[i] = defaultFromZigInterop;
        }
    }

    return buildMethodArgsImpl(sdk, scope, method_metadata, args, param_interop_fns);
}

test {
    std.testing.refAllDecls(@This());
}

test "basic interops" {
    const Foo = ManagedObjectTypeBuilder("app.foo")
        .Method(.getBar, void, null)
        .Param("System.Int32", u32, null)
        .Build();

    try std.testing.expect(comptime @TypeOf(Foo) == type);

    var dummy_cache: ManagedTypeCache = .init(std.testing.allocator, std.testing.io);
    var dummy_sdk: InteropSdk = undefined;
    const dummy_typedef: api.sdk.TypeDefinition = undefined;
    var dummy_data: ?*anyopaque = null;
    var scope = dummy_cache.newScope(std.testing.allocator);
    defer scope.deinit();
    {
        const res = try defaultToZigInterop(void)(&dummy_sdk, &scope, dummy_typedef, &dummy_data);
        try std.testing.expect(comptime @TypeOf(res) == void);
    }

    {
        @setRuntimeSafety(false);
        var invoke_res: api.InvokeRet = .{};
        invoke_res.bytes[0] = 69;
        const res = try defaultToZigInterop(u8)(
            &dummy_sdk,
            &scope,
            dummy_typedef,
            @ptrCast(@alignCast(&invoke_res.bytes[0])),
        );
        try std.testing.expectEqual(invoke_res.as(u8), res);
    }

    {
        @setRuntimeSafety(false);
        var arg: u32 = undefined;
        try defaultFromZigInterop(&dummy_sdk, &scope, dummy_typedef, 420, @ptrCast(@alignCast(&arg)));
        try std.testing.expectEqual(420, arg);
    }

    {
        @setRuntimeSafety(false);
        const vec2f = extern struct { x: f32, y: f32 };
        var arg: vec2f = .{ .x = 70.0, .y = 320.0 };
        const res = try defaultToZigInterop(@Vector(2, f32))(
            &dummy_sdk,
            &scope,
            dummy_typedef,
            @ptrCast(@alignCast(&arg)),
        );
        try std.testing.expectEqual(70.0, res[0]);
        try std.testing.expectEqual(320.0, res[1]);
    }

    {
        @setRuntimeSafety(false);
        const vec3f = extern struct { x: f32, y: f32, z: f32 };
        var arg: vec3f = .{ .x = 70.0, .y = 320.0, .z = 911.0 };
        const res = try defaultToZigInterop(@Vector(3, f32))(
            &dummy_sdk,
            &scope,
            dummy_typedef,
            @ptrCast(@alignCast(&arg)),
        );
        try std.testing.expectEqual(70.0, res[0]);
        try std.testing.expectEqual(320.0, res[1]);
        try std.testing.expectEqual(911.0, res[2]);
    }

    {
        @setRuntimeSafety(false);
        const vec4f = extern struct { x: f32, y: f32, z: f32, w: f32 };
        var arg: vec4f = .{ .x = 70.0, .y = 320.0, .z = 911.0, .w = 1234.0 };
        const res = try defaultToZigInterop(@Vector(4, f32))(
            &dummy_sdk,
            &scope,
            dummy_typedef,
            @ptrCast(@alignCast(&arg)),
        );
        try std.testing.expectEqual(70.0, res[0]);
        try std.testing.expectEqual(320.0, res[1]);
        try std.testing.expectEqual(911.0, res[2]);
        try std.testing.expectEqual(1234.0, res[3]);
    }
}
