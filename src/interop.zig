const std = @import("std");
const api = @import("api.zig");
const type_utils = @import("type_utils.zig");

const native = std.builtin.Endian.native;

inline fn isManagedInterop(T: type) bool {
    return type_utils.isPureStruct(T) and @hasField(T, "managed") and
        @hasField(T, "runtime") and @hasDecl(T, "Runtime") and
        @hasDecl(T.Runtime, "checkedInit");
}

const MethodMetadata = struct {
    handle: api.sdk.Method,
    ret_type_def: api.sdk.TypeDefinition,
    param_type_defs: []api.sdk.TypeDefinition,

    const Self = @This();

    fn init(
        allocator: std.mem.Allocator,
        sdk: api.VerifiedSdk(.{
            .method = sdk_managed_specs.method,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
        handle: api.sdk.Method,
    ) !Self {
        const ret_type_def = handle.getReturnType(.fo(sdk)) orelse return error.MethodReturnTypeDefMissing;
        const params_len = handle.getNumParams(.fo(sdk));
        var param_type_defs: std.ArrayList(api.sdk.TypeDefinition) = .empty;
        defer param_type_defs.deinit(allocator);
        if (params_len > 0) {
            var params: std.ArrayList(api.sdk.Method.Parameter) = .empty;
            defer params.deinit(allocator);

            const out =
                try handle.getParams(
                    .fo(sdk),
                    try params.addManyAsSlice(allocator, params_len),
                );

            for (out) |param| {
                try param_type_defs.append(allocator, param.typeDefinition());
            }
        }

        return .{
            .handle = handle,
            .ret_type_def = ret_type_def,
            .param_type_defs = try param_type_defs.toOwnedSlice(allocator),
        };
    }

    fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.param_type_defs);
    }
};

// https://github.com/praydog/REFramework/blob/ce9df1fe81e897c117d85ac9c4446a1a453b938f/shared/sdk/RETypeDefinition.cpp#L434
const FieldMetadata = struct {
    handle: api.sdk.Field,
    type_def: api.sdk.TypeDefinition,
};

const ManagedObjectMetadata = struct {
    // They store TypeDefinition in a global map meaning it's almost like a static storage...
    // https://github.com/praydog/REFramework/blob/ce9df1fe81e897c117d85ac9c4446a1a453b938f/shared/sdk/RETypeDB.cpp#L20
    type_def: api.sdk.TypeDefinition,
    methods: []MethodMetadata,
    fields: []FieldMetadata,
};

const TypeDefMetadata = struct {
    methods: std.StringHashMap(MethodMetadata),
    fields: std.StringHashMap(FieldMetadata),

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{ .methods = .init(allocator), .fields = .init(allocator) };
    }
};

const TypeDefContext = struct {
    pub fn hash(ctx: @This(), key: api.sdk.TypeDefinition) u64 {
        _ = ctx;
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&key.raw));
    }
    pub fn eql(ctx: @This(), a: api.sdk.TypeDefinition, b: api.sdk.TypeDefinition) bool {
        _ = ctx;
        return a.raw == b.raw;
    }
};

// Every check is at runtime, don't know any better way of doing it...
pub const Cache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    type_def_map: std.HashMap(
        api.sdk.TypeDefinition,
        TypeDefMetadata,
        TypeDefContext,
        std.hash_map.default_max_load_percentage,
    ),
    managed_metadata: std.StringHashMap(ManagedObjectMetadata),
    diagnostics: std.ArrayList(u8),
    mutex: std.Io.Mutex = .init,

    const Self = @This();

    /// `allocator` needs to be thread safe!
    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .io = io,
            .allocator = allocator,
            .type_def_map = .init(allocator),
            .managed_metadata = .init(allocator),
            .diagnostics = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        {
            var values_iter = self.type_def_map.valueIterator();
            while (values_iter.next()) |metadata| {
                var methods = metadata.methods.valueIterator();
                while (methods.next()) |method| {
                    method.deinit(self.allocator);
                }

                metadata.methods.deinit();
                metadata.fields.deinit();
            }
        }
        {
            var values_iter = self.managed_metadata.valueIterator();
            while (values_iter.next()) |metadata| {
                self.allocator.free(metadata.methods);
                self.allocator.free(metadata.fields);
            }
        }

        self.type_def_map.deinit();
        self.managed_metadata.deinit();
        self.diagnostics.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ownDiagnostics(self: *Self) ![:0]const u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        return self.diagnostics.toOwnedSliceSentinel(self.allocator, 0);
    }

    pub fn lock(self: *Self) !void {
        return self.mutex.lock(self.io);
    }

    pub fn unlock(self: *Self) void {
        return self.mutex.unlock(self.io);
    }

    pub fn callMethod(
        self: *Self,
        sdk: api.VerifiedSdk(.{
            .method = sdk_managed_specs.method,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
        managed: api.sdk.ManagedObject,
        comptime sig: [:0]const u8,
        comptime param_interops: anytype,
        comptime ret: anytype,
        args: anytype,
    ) !ret.type {
        @setRuntimeSafety(false);

        if (!type_utils.isTuple(@TypeOf(param_interops))) {
            @compileError("Please pass interops as tuple values");
        }
        if (!type_utils.isPureStruct(@TypeOf(ret))) {
            @compileError("Please provide 'ret' with 'type', 'interop' fields.");
        }
        if (!type_utils.isTuple(@TypeOf(args))) {
            @compileError("'args' has to be a tuple");
        }

        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const type_def = managed.getTypeDefinition(.fo(sdk)) orelse return error.NoTypeDefFound;
        const type_def_entry = try self.type_def_map.getOrPutValue(type_def, .init(self.allocator));

        const method_sig = sig;

        const method_cache_entry = try type_def_entry.value_ptr.methods.getOrPut(method_sig);
        const method_metadata = if (method_cache_entry.found_existing) blk: {
            break :blk method_cache_entry.value_ptr.*;
        } else blk: {
            const handle = type_def.findMethod(.fromOther(sdk), method_sig) orelse {
                return error.MethodNotFound;
            };
            const new_method_metadata = try MethodMetadata.init(self.allocator, .fo(sdk), handle);
            method_cache_entry.value_ptr.* = new_method_metadata;
            break :blk new_method_metadata;
        };

        const ParamInteropsT = @TypeOf(param_interops);
        const param_interops_len = comptime std.meta.fields(ParamInteropsT).len;
        const args_len = comptime std.meta.fields(@TypeOf(args)).len;
        if (param_interops_len > 0 and param_interops_len != args_len) {
            @compileError("param_interops len has to match the args length or has to be 0");
        }

        var built_args: [args_len]?*anyopaque = undefined;

        if (param_interops_len > 0) {
            inline for (0..args_len) |i| {
                const arg_index_str = std.fmt.comptimePrint("{d}", .{i});
                const arg = @field(args, arg_index_str);
                try @field(param_interops, arg_index_str)(
                    @constCast(&sdk),
                    method_metadata.param_type_defs[i],
                    arg,
                    &built_args[i],
                );
            }
        } else {
            inline for (0..args_len) |i| {
                const arg_index_str = std.fmt.comptimePrint("{d}", .{i});
                const arg = @field(args, arg_index_str);
                try defaultFromZigInterop(
                    @constCast(&sdk),
                    method_metadata.param_type_defs[i],
                    arg,
                    &built_args[i],
                );
            }
        }

        var invoke_res = try managed.invokeMethod(method_metadata.handle, .fo(sdk), &built_args);

        const p: *?*anyopaque = @ptrCast(@alignCast(&invoke_res.bytes[0]));
        // https://github.com/praydog/REFramework/blob/63dd83ead22bbab924b93bbd32e5be36d3a09a4d/src/mods/bindings/Sdk.cpp#L960
        // TODO: Use type full name?
        if (ret.type == f32 and !@hasField(@TypeOf(ret), "interop")) {
            return @floatCast(try defaultToZigInterop(f64)(
                @constCast(&sdk),
                self,
                method_metadata.ret_type_def,
                p,
            ));
        } else {
            const retInterop = if (@hasField(@TypeOf(ret), "interop"))
                ret.interop
            else
                defaultToZigInterop(ret.type);

            return try retInterop(
                @constCast(&sdk),
                self,
                method_metadata.ret_type_def,
                p,
            );
        }
    }

    pub fn getField(
        self: *Self,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
        managed: api.sdk.ManagedObject,
        comptime T: type,
        comptime field_data: anytype,
    ) !T {
        @setRuntimeSafety(false);

        const field = comptime if (@TypeOf(field_data) == @EnumLiteral()) .{
            .name = @tagName(field_data),
        } else field_data;
        const FieldT = @TypeOf(field);
        if (!type_utils.isPureStruct(FieldT)) {
            @compileError("Please provide 'field_data' with 'name', 'get' fields or just @EnumLiteral with the field name.");
        }

        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const type_def = managed.getTypeDefinition(.fo(sdk)) orelse return error.NoTypeDefFound;
        const type_def_entry = try self.type_def_map.getOrPutValue(type_def, .init(self.allocator));

        const field_name = comptime field.name;

        const field_cache_entry = try type_def_entry.value_ptr.fields.getOrPut(field_name);
        const field_metadata: FieldMetadata = if (field_cache_entry.found_existing) blk: {
            break :blk field_cache_entry.value_ptr.*;
        } else blk: {
            const field_handle = type_def.findField(.fo(sdk), field_name) orelse {
                return error.FieldNotFound;
            };
            const field_type_def = field_handle.getType(.fo(sdk)) orelse {
                return error.FieldInvalidType;
            };
            const new_field_metadata: FieldMetadata = .{
                .handle = field_handle,
                .type_def = field_type_def,
            };
            field_cache_entry.value_ptr.* = new_field_metadata;
            break :blk new_field_metadata;
        };

        const field_handle = field_metadata.handle;

        const data_read_ptr: *?*anyopaque = @ptrCast(@alignCast(field_handle.getDataRaw(
            .fo(sdk),
            managed.raw,
            false,
        )));

        const getInterop = if (@hasField(FieldT, "get"))
            field.get
        else
            defaultToZigInterop(T);

        return try getInterop(
            @constCast(&sdk),
            self,
            field_metadata.type_def,
            data_read_ptr,
        );
    }

    pub fn setField(
        self: *Self,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
        managed: api.sdk.ManagedObject,
        comptime field_data: anytype,
        value: anytype,
    ) !void {
        @setRuntimeSafety(false);

        const field = comptime if (@TypeOf(field_data) == @EnumLiteral()) .{
            .name = @tagName(field_data),
        } else field_data;
        const FieldT = @TypeOf(field);
        if (!type_utils.isPureStruct(FieldT)) {
            @compileError("Please provide 'field_data' with 'name', 'set' fields or just @EnumLiteral with the field name.");
        }

        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const type_def = managed.getTypeDefinition(.fo(sdk)) orelse return error.NoTypeDefFound;
        const type_def_entry = try self.type_def_map.getOrPutValue(type_def, .init(self.allocator));

        const field_name = comptime field.name;

        const field_cache_entry = try type_def_entry.value_ptr.fields.getOrPut(field_name);
        const field_metadata: FieldMetadata = if (field_cache_entry.found_existing) blk: {
            break :blk field_cache_entry.value_ptr.*;
        } else blk: {
            const field_handle = type_def.findField(.fo(sdk), field_name) orelse {
                return error.FieldNotFound;
            };
            const field_type_def = field_handle.getType(.fo(sdk)) orelse {
                return error.FieldInvalidType;
            };
            const new_field_metadata: FieldMetadata = .{
                .handle = field_handle,
                .type_def = field_type_def,
            };
            field_cache_entry.value_ptr.* = new_field_metadata;
            break :blk new_field_metadata;
        };

        const field_handle = field_metadata.handle;

        const data_write_ptr: *?*anyopaque = @ptrCast(@alignCast(field_handle.getDataRaw(
            .fo(sdk),
            managed.raw,
            false,
        )));

        const setInterop = if (@hasField(FieldT, "set"))
            field.set
        else
            defaultFromZigInterop;

        try setInterop(
            @constCast(&sdk),
            field_metadata.type_def,
            value,
            data_write_ptr,
        );
    }

    fn appendError(self: *Self, err: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        try self.diagnostics.appendSlice(self.allocator, err);
        try self.diagnostics.append(self.allocator, '\n');
    }

    fn validationDone(self: *Self, type_name: []const u8, metadata: ManagedObjectMetadata) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        try self.managed_metadata.put(type_name, metadata);
    }

    fn getTypeMetadata(self: *Self, type_name: []const u8) ?ManagedObjectMetadata {
        self.mutex.lock(self.io) catch return null;
        defer self.mutex.unlock(self.io);

        return self.managed_metadata.get(type_name);
    }
};

const sdk_managed_specs = .{
    .functions = .{
        .create_managed_string_normal,
    },
    .managed_object = .get_type_definition,
    .method = .{
        .invoke,
        .get_return_type,
        .get_num_params,
        .get_params,
    },
    .field = .{
        .get_data_raw,
        .get_type,
    },
    .type_definition = .all,
};

const ManagedSdk = api.VerifiedSdk(sdk_managed_specs);

pub fn defaultFromZigInterop(
    userdata: ?*anyopaque,
    to_type_def: api.sdk.TypeDefinition,
    arg: anytype,
    out: *?*anyopaque,
) anyerror!void {
    @setRuntimeSafety(false);
    const sdk_ptr: *ManagedSdk = @ptrCast(@alignCast(userdata));
    const sdk = sdk_ptr.*;

    const ArgT = @TypeOf(arg);
    switch (ArgT) {
        [:0]const u8 => {
            const managed_string = api.sdk.safe().createManagedStringNormal(.fo(sdk), arg) orelse return error.FailedToCreateString;
            out.* = @ptrCast(managed_string.raw);
            return;
        },
        [:0]u8 => {
            const managed_string = api.sdk.safe().createManagedStringNormal(.fo(sdk), arg) orelse return error.FailedToCreateString;
            out.* = @ptrCast(managed_string.raw);
            return;
        },
        *const [:0]const u8 => {
            const managed_string = api.sdk.safe().createManagedStringNormal(.fo(sdk), arg.*) orelse return error.FailedToCreateString;
            out.* = @ptrCast(managed_string.raw);
            return;
        },
        *[:0]u8 => {
            const managed_string = api.sdk.safe().createManagedStringNormal(.fo(sdk), arg.*) orelse return error.FailedToCreateString;
            out.* = @ptrCast(managed_string.raw);
            return;
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
        else => {},
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
                std.mem.writeInt(u32, b[0..@sizeOf(u32)], @intFromFloat(arg), native);
            } else {
                std.mem.writeInt(u64, b[0..@sizeOf(u64)], @intFromFloat(arg), native);
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
            const enum_int = @intFromEnum(arg);
            const EnumIntT = if (@TypeOf(enum_int) == comptime_int) c_int else @TypeOf(enum_int);

            const b: [*]u8 = @ptrCast(out);
            std.mem.writeInt(EnumIntT, b[0..@sizeOf(EnumIntT)], enum_int, native);
            return;
        },
        .@"struct" => {
            if (isManagedInterop(ArgT)) {
                out.* = @ptrCast(arg.managed.raw);
            } else {
                @compileError("Cannot interop zig struct");
            }
            return;
        },
        .optional => {
            if (arg) |v| {
                defaultFromZigInterop(sdk_ptr, to_type_def, v, out);
            } else {
                out.* = null;
            }
            return;
        },
        .pointer => |p| {
            if (isManagedInterop(p.child)) {
                out.* = @ptrCast(arg.managed.raw);
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

pub fn defaultToZigInterop(RetType: type) fn (?*anyopaque, *Cache, api.sdk.TypeDefinition, *?*anyopaque) anyerror!RetType {
    return struct {
        fn func(
            userdata: ?*anyopaque,
            cache: *Cache,
            from_type_def: api.sdk.TypeDefinition,
            data: *?*anyopaque,
        ) anyerror!RetType {
            @setRuntimeSafety(false);
            _ = from_type_def;
            if (RetType == void) return {};

            const sdk_ptr: *ManagedSdk = @ptrCast(@alignCast(userdata));
            const sdk = sdk_ptr.*;

            switch (RetType) {
                api.sdk.ManagedObject => {
                    const ptr: ?*anyopaque = data.*;
                    if (ptr == null) return error.ReturnedUnexpectedNull;
                    return .{ .raw = @ptrCast(@alignCast(ptr)) };
                },
                else => {},
            }

            const ret_t_info = @typeInfo(RetType);
            if (isManagedInterop(RetType)) {
                const ptr: ?*anyopaque = data.*;
                if (ptr == null) return error.ReturnedUnexpectedNull;
                const obj: api.sdk.ManagedObject = .{ .raw = @ptrCast(@alignCast(ptr)) };
                return try RetType.init(cache, sdk, obj);
            } else switch (ret_t_info) {
                .int => {
                    const b: [*]const u8 = @ptrCast(data);
                    return std.mem.readInt(RetType, b[0..@sizeOf(RetType)], native);
                },
                .float => |float| {
                    const b: [*]const u8 = @ptrCast(data);
                    if (float.bits >= 0 and float.bits <= 32) {
                        return @floatCast(@as(f32, @floatFromInt(std.mem.readInt(u32, b[0..@sizeOf(u32)], native))));
                    } else if (float.bits <= 64) {
                        return @floatCast(@as(f64, @floatFromInt(std.mem.readInt(u64, b[0..@sizeOf(u64)], native))));
                    } else {
                        return @floatCast(@as(f128, @floatFromInt(std.mem.readInt(u128, b[0..@sizeOf(u128)], native))));
                    }
                },
                .bool => {
                    const b: [*]const u8 = @ptrCast(data);
                    return if (b[0] > 0) true else false;
                },
                .optional => |o| {
                    if (isManagedInterop(o.child)) {
                        const ptr: ?*anyopaque = data.*;
                        if (ptr == null) return null;
                        const obj: api.sdk.ManagedObject = .{ .raw = @ptrCast(@alignCast(ptr)) };
                        return try o.child.init(cache, sdk, obj);
                    } else if (o.child == api.sdk.ManagedObject) {
                        const ptr: ?*anyopaque = data.*;
                        if (ptr == null) return null;
                        const obj: api.sdk.ManagedObject = .{ .raw = @ptrCast(@alignCast(ptr)) };
                        return obj;
                    } else if (@typeInfo(o.child) == .pointer) {
                        const ptr: ?*anyopaque = data.*;
                        if (ptr == null) return null;
                        return @ptrCast(@alignCast(ptr));
                    } else {
                        @compileError("Cannot interop type: '" ++ @typeName(RetType) ++ "'");
                    }
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
    type_name: [:0]const u8,
    type: type,
    comptime interop: fn (
        userdata: ?*anyopaque,
        to_type_def: api.sdk.TypeDefinition,
        arg: anytype,
        out: *?*anyopaque,
    ) anyerror!void = defaultFromZigInterop,
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

fn getMethodData(comptime methods: anytype, comptime method: @EnumLiteral()) type {
    const method_names = std.meta.fieldNames(@TypeOf(methods));
    inline for (method_names, 0..) |method_name, i| {
        if (std.mem.eql(u8, method_name, @tagName(method))) {
            return MethodData(@field(methods, @tagName(method)), i);
        }
    }

    @compileError("'" ++ @tagName(method) ++ "' was not found");
}

inline fn buildMethodSignature(comptime method_name: []const u8, comptime params: anytype) [:0]const u8 {
    return comptime blk: {
        var sig: [:0]const u8 = method_name ++ "(";

        const params_len = std.meta.fields(@TypeOf(params)).len;
        if (params_len > 0) {
            sig = std.fmt.comptimePrint("{s}{s}", .{ sig, params.@"0".type_name });
            for (1..params_len) |i| {
                sig = std.fmt.comptimePrint("{s},{s}", .{ sig, @field(params, std.fmt.comptimePrint("{d}", .{i})).type_name });
            }
        }
        sig = std.fmt.comptimePrint("{s})", .{sig});
        break :blk sig;
    };
}

fn buildMethodArgs(
    Data: type,
    userdata: ?*anyopaque,
    method_metadata: MethodMetadata,
    args: anytype,
) anyerror![Data.getParamsLen()]?*anyopaque {
    const params_len = Data.getParamsLen();
    const args_len = std.meta.fields(@TypeOf(args)).len;

    if (params_len != args_len) {
        @compileError(std.fmt.comptimePrint("Expected args len: {d}, found: {d}", .{ params_len, args_len }));
    }

    var out: [params_len]?*anyopaque = undefined;

    inline for (0..params_len) |i| {
        const arg = @field(args, std.fmt.comptimePrint("{d}", .{i}));
        try Data.getParam(i).interop(
            userdata,
            method_metadata.param_type_defs[i],
            arg,
            &out[i],
        );
    }

    return out;
}

fn FieldData(comptime fields: anytype, comptime field: @EnumLiteral()) type {
    const field_names = std.meta.fieldNames(@TypeOf(fields));
    inline for (field_names, 0..) |field_name, i| {
        if (std.mem.eql(u8, field_name, @tagName(field))) {
            return struct {
                const Data = @TypeOf(@field(fields, @tagName(field)));
                const DefaultInterop = defaultFieldInterop(get().type);
                fn get() Data {
                    return @field(fields, @tagName(field));
                }
                fn getIndex() @TypeOf(i) {
                    return i;
                }
                fn getGetInterop() @TypeOf(if (@hasField(Data, "get")) get().get else DefaultInterop.get) {
                    return if (@hasField(Data, "get")) get().get else DefaultInterop.get;
                }
                fn getSetInterop() @TypeOf(if (@hasField(Data, "set")) get().get else DefaultInterop.set) {
                    return if (@hasField(Data, "set")) get().set else DefaultInterop.set;
                }
            };
        }
    }
}

fn defaultFieldInterop(FieldType: type) type {
    return struct {
        inline fn get(
            userdata: ?*anyopaque,
            cache: *Cache,
            from_type_def: api.sdk.TypeDefinition,
            field_raw_data: *?*anyopaque,
        ) anyerror!FieldType {
            // TODO: Add more safety fences?
            return defaultToZigInterop(FieldType)(userdata, cache, from_type_def, field_raw_data);
        }

        inline fn set(
            userdata: ?*anyopaque,
            to_type_def: api.sdk.TypeDefinition,
            value: FieldType,
            write_ptr: *?*anyopaque,
        ) anyerror!void {
            return defaultFromZigInterop(userdata, to_type_def, value, write_ptr);
        }
    };
}

/// methods = .{
///     .@"method name": Method,
///     .@"method name2": Method,
/// }
/// const Method = struct {
///     .name = null, // when needs to set some custom name, usually used for overloads..
///     .ret = .{
///         .type: type,
///         // the cache where the current ManagedObject is "cached" in.
///         .interop: fn (userdata: ?*anyopaque, cache: *Cache, ret_result: api.sdk.InvokeRet, out: *?*anyopaque) method.ret.type = defaultToZigInterop,
///     },
///     params: []const MethodParam,
/// };
/// const MethodParam = struct {
///     type_name: [:0]const u8,
///     type: type,
///     comptime interop: fn (userdata: ?*anyopaque, arg: anytype, out: *?*anyopaque) anyerror!void = defaultFromZigInterop,
/// };
/// fields = .{
///     .@"field name": Field,
/// }
/// const Field = struct {
///     type: type,
///     comptime get: fn (userdata: ?*anyopaque, cache: *Cache, ret_result: api.sdk.InvokeRet, out: *?*anyopaque) field.type = defaultToZigInterop,
///     comptime set: fn (userdata: ?*anyopaque, arg: anytype, out: *?*anyopaque) anyerror!void = defaultFromZigInterop,
/// };
pub fn ManagedObject(
    comptime full_type_name: [:0]const u8,
    comptime methods: anytype,
    comptime fields: anytype,
) type {
    const ManagedObjectType = struct {
        metadata: ManagedObjectMetadata,
        cache: *Cache,

        const ManagedObjectType = @This();

        pub const Instance = struct {
            managed: api.sdk.ManagedObject,
            runtime: Runtime,

            const Self = @This();
            pub const Runtime = ManagedObjectType;

            pub fn init(cache: *Cache, sdk: ManagedSdk, managed: api.sdk.ManagedObject) !Self {
                return checkedInit(cache, sdk, managed);
            }

            pub fn f(other: anytype) Self {
                const OtherT = @TypeOf(other);
                if (isManagedInterop(OtherT)) {
                    @compileError("'other' has to be a ManagedObject interop type");
                }
                if (!std.mem.eql(u8, full_type_name, OtherT.fullTypeName())) {
                    @compileError("'" ++ full_type_name ++ "' type is not compatible with '" ++ OtherT.fullTypeName() ++ "'");
                }

                return .{ .managed = other.managed, .runtime = other.runtime };
            }

            /// The provided sdk will be the userdata for each user-defined interop
            /// functions, we just won't have any compile-time checks for this.
            pub fn call(
                self: Self,
                comptime method: @EnumLiteral(),
                sdk: ManagedSdk,
                args: anytype,
            ) !getMethodData(methods, method).RetType() {
                @setRuntimeSafety(false);
                if (!type_utils.isTuple(@TypeOf(args))) {
                    @compileError("'args' needs to be a tuple");
                }

                const Data = getMethodData(methods, method);
                const method_data = Data.get();

                const method_metadata = self.runtime.metadata.methods[Data.getIndex()];
                // don't care if the "sdk" value was modified, it gets discarded anyways.
                var built_args = try buildMethodArgs(Data, @constCast(&sdk), method_metadata, args);

                var invoke_res = try self.managed.invokeMethod(method_metadata.handle, .fo(sdk), &built_args);

                const p: *?*anyopaque = @ptrCast(@alignCast(&invoke_res.bytes[0]));
                if (!@hasField(@TypeOf(method_data), "ret")) {
                    return try defaultToZigInterop(void)(
                        @constCast(&sdk),
                        self.runtime.cache,
                        method_metadata.ret_type_def,
                        p,
                    );
                } else {
                    // https://github.com/praydog/REFramework/blob/63dd83ead22bbab924b93bbd32e5be36d3a09a4d/src/mods/bindings/Sdk.cpp#L960
                    // TODO: Use type full name?
                    if (method_data.ret.type == f32 and !@hasField(@TypeOf(method_data.ret), "interop")) {
                        return @floatCast(try defaultToZigInterop(f64)(
                            @constCast(&sdk),
                            self.runtime.cache,
                            method_metadata.ret_type_def,
                            p,
                        ));
                    } else {
                        const retInterop = if (@hasField(@TypeOf(method_data.ret), "interop"))
                            method_data.ret.interop
                        else
                            defaultToZigInterop(method_data.ret.type);

                        return try retInterop(
                            @constCast(&sdk),
                            self.runtime.cache,
                            method_metadata.ret_type_def,
                            p,
                        );
                    }
                }
            }

            // https://github.com/praydog/REFramework/blob/63dd83ead22bbab924b93bbd32e5be36d3a09a4d/src/mods/bindings/Sdk.cpp#L1246
            pub fn get(
                self: Self,
                comptime field: @EnumLiteral(),
                sdk: ManagedSdk,
            ) !FieldData(fields, field).get().type {
                @setRuntimeSafety(false);
                const Data = FieldData(fields, field);

                const field_metadata = self.runtime.metadata.fields[Data.getIndex()];
                const field_handle = field_metadata.handle;

                const data_read_ptr: *?*anyopaque = @ptrCast(@alignCast(field_handle.getDataRaw(
                    .fo(sdk),
                    self.managed.raw,
                    false,
                )));
                return try Data.getGetInterop()(
                    @constCast(&sdk),
                    self.runtime.cache,
                    field_metadata.type_def,
                    data_read_ptr,
                );
            }

            // https://github.com/praydog/REFramework/blob/63dd83ead22bbab924b93bbd32e5be36d3a09a4d/src/mods/bindings/Sdk.cpp#L1232
            pub fn set(
                self: Self,
                comptime field: @EnumLiteral(),
                sdk: ManagedSdk,
                value: FieldData(fields, field).get().type,
            ) !void {
                @setRuntimeSafety(false);
                const Data = FieldData(fields, field);

                const field_metadata = self.runtime.metadata.fields[Data.getIndex()];
                const field_handle = field_metadata.handle;

                const data_write_ptr: *?*anyopaque = @ptrCast(@alignCast(field_handle.getDataRaw(
                    .fo(sdk),
                    self.managed.raw,
                    false,
                )));
                try Data.getSetInterop()(
                    @constCast(&sdk),
                    field_metadata.type_def,
                    value,
                    data_write_ptr,
                );
            }

            pub inline fn fullTypeName() [:0]const u8 {
                return full_type_name;
            }
        };

        pub fn get(cache: *Cache, sdk: ManagedSdk.Extend(.{
            .functions = .{ .extend = .get_tdb },
            .tdb = .find_type,
        })) !ManagedObjectType {
            if (cache.getTypeMetadata(full_type_name)) |metadata| {
                return .{
                    .metadata = metadata,
                    .cache = cache,
                };
            }
            const tdb = api.sdk.getTdb(.fo(sdk)) orelse return error.TdbNull;
            const type_def = tdb.findType(.fo(sdk), full_type_name) orelse return error.NoTypeDefFound;
            return checkedRuntime(cache, .fo(sdk), type_def);
        }

        pub fn getWithTdb(cache: *Cache, sdk: ManagedSdk.Extend(.{ .tdb = .find_type }), tdb: api.sdk.Tdb) !ManagedObjectType {
            if (cache.getTypeMetadata(full_type_name)) |metadata| {
                return .{
                    .metadata = metadata,
                    .cache = cache,
                };
            }
            const type_def = tdb.findType(.fo(sdk), full_type_name) orelse return error.NoTypeDefFound;
            return checkedRuntime(cache, .fo(sdk), type_def);
        }

        pub fn instance(self: ManagedObjectType, managed: api.sdk.ManagedObject) Instance {
            return .{ .managed = managed, .runtime = self };
        }

        pub fn getMethod(self: ManagedObjectType, comptime method: @EnumLiteral()) api.sdk.Method {
            comptime var found = false;
            const method_names = comptime std.meta.fieldNames(@TypeOf(methods));
            inline for (method_names, 0..) |method_name, i| {
                if (comptime std.mem.eql(u8, method_name, @tagName(method))) {
                    found = true;
                    return self.metadata.methods[i].handle;
                }
            }

            if (!found) {
                @compileError("No method decl was found with name: " ++ @tagName(method));
            }
        }

        fn checkedInit(cache: *Cache, sdk: ManagedSdk, managed: api.sdk.ManagedObject) !Instance {
            if (cache.getTypeMetadata(full_type_name)) |metadata| {
                return .{
                    .managed = managed,
                    .runtime = .{
                        .metadata = metadata,
                        .cache = cache,
                    },
                };
            }

            const type_def = managed.getTypeDefinition(.fo(sdk)) orelse return error.NoTypeDefFound;
            return .{
                .managed = managed,
                .runtime = try checkedRuntime(cache, sdk, type_def),
            };
        }

        fn checkedRuntime(cache: *Cache, sdk: ManagedSdk, type_def: api.sdk.TypeDefinition) !ManagedObjectType {
            const method_names = comptime std.meta.fieldNames(@TypeOf(methods));
            var collected_methods = try std.ArrayList(MethodMetadata).initCapacity(cache.allocator, method_names.len);
            defer collected_methods.deinit(cache.allocator);

            const field_names = comptime std.meta.fieldNames(@TypeOf(fields));
            var collected_fields = try std.ArrayList(FieldMetadata).initCapacity(cache.allocator, field_names.len);
            defer collected_fields.deinit(cache.allocator);
            {
                try cache.lock();
                defer cache.unlock();

                // getting existing cached type_def metadata...
                const type_def_entry = try cache.type_def_map.getOrPutValue(type_def, .init(cache.allocator));

                // Checking methods
                inline for (method_names) |default_method_name| {
                    // TODO: Check param Types, Return Type for interoperability.
                    const method_metadata = @field(methods, default_method_name);
                    const method_name = if (@hasField(@TypeOf(method_metadata), "name"))
                        method_metadata.name
                    else
                        default_method_name;
                    const method_sig = buildMethodSignature(method_name, method_metadata.params);

                    const method_cache_entry = try type_def_entry.value_ptr.methods.getOrPut(method_sig);
                    if (method_cache_entry.found_existing) {
                        try collected_methods.append(
                            cache.allocator,
                            method_cache_entry.value_ptr.*,
                        );
                    } else {
                        const method = type_def.findMethod(.fromOther(sdk), method_sig) orelse {
                            cache.appendError("'" ++ method_sig ++ "' was not found in '" ++ full_type_name ++ "'") catch {};
                            return error.MethodNotFound;
                        };
                        // Disclaimer: Deiniting one of them is enough to free all
                        // the resources associated with it, make sure to call deinit
                        // once during one of the map/list owner free.
                        const new_method_metadata = try MethodMetadata.init(cache.allocator, .fo(sdk), method);
                        method_cache_entry.value_ptr.* = new_method_metadata;
                        try collected_methods.append(
                            cache.allocator,
                            new_method_metadata,
                        );
                    }
                }

                // Checking fields
                inline for (field_names) |field_name| {
                    // TODO: Check field Types for interoperability.
                    const field_cache_entry = try type_def_entry.value_ptr.fields.getOrPut(field_name);

                    if (field_cache_entry.found_existing) {
                        try collected_fields.append(cache.allocator, field_cache_entry.value_ptr.*);
                    } else {
                        const field_handle = type_def.findField(.fo(sdk), field_name) orelse {
                            cache.appendError("'" ++ field_name ++ "' was not found in '" ++ full_type_name ++ "'") catch {};
                            return error.FieldNotFound;
                        };
                        const field_type_def = field_handle.getType(.fo(sdk)) orelse {
                            cache.appendError("'" ++ full_type_name ++ "." ++ field_name ++ "' doesn't have any valid Type Definition") catch {};
                            return error.FieldInvalidType;
                        };
                        const new_field_metadata: FieldMetadata = .{
                            .handle = field_handle,
                            .type_def = field_type_def,
                        };
                        field_cache_entry.value_ptr.* = new_field_metadata;
                        try collected_fields.append(cache.allocator, new_field_metadata);
                    }
                }
            }

            const metadata = ManagedObjectMetadata{
                .type_def = type_def,
                .methods = try collected_methods.toOwnedSlice(cache.allocator),
                .fields = try collected_fields.toOwnedSlice(cache.allocator),
            };
            try cache.validationDone(full_type_name, metadata);
            return .{
                .metadata = metadata,
                .cache = cache,
            };
        }
    };

    return ManagedObjectType.Instance;
}

test "basic" {
    const Foo = ManagedObject(
        "app.foo",
        .{
            .getBar = .{
                .params = .{
                    .{ .type_name = "System.Int32", .type = u32 },
                },
            },
        },
        .{},
    );

    try std.testing.expect(comptime @TypeOf(Foo) == type);

    var dummy_cache: Cache = .init(std.testing.allocator, std.testing.io);
    var dummy_sdk: ManagedSdk = undefined;
    const dummy_typedef: api.sdk.TypeDefinition = undefined;
    var dummy_data: ?*anyopaque = null;
    {
        const res = try defaultToZigInterop(void)(&dummy_sdk, &dummy_cache, dummy_typedef, &dummy_data);
        try std.testing.expect(comptime @TypeOf(res) == void);
    }

    {
        @setRuntimeSafety(false);
        var invoke_res: api.InvokeRet = .{};
        invoke_res.bytes[0] = 69;
        const res = try defaultToZigInterop(u8)(
            &dummy_sdk,
            &dummy_cache,
            dummy_typedef,
            @ptrCast(@alignCast(&invoke_res.bytes[0])),
        );
        try std.testing.expectEqual(69, res);
    }

    {
        @setRuntimeSafety(false);
        var arg: u32 = undefined;
        try defaultFromZigInterop(&dummy_sdk, dummy_typedef, 420, @ptrCast(@alignCast(&arg)));
        try std.testing.expectEqual(420, arg);
    }
}
