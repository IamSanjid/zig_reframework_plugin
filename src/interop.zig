const std = @import("std");
const api = @import("api.zig");
const type_utils = @import("type_utils.zig");

const native = std.builtin.Endian.native;
const optimize_mode = @import("build_options").optimize_mode;

inline fn isSafeMode() bool {
    return optimize_mode == .Debug or optimize_mode == .ReleaseSafe;
}

inline fn isManagedInterop(T: type) bool {
    return type_utils.isPureStruct(T) and @hasField(T, "managed") and
        @hasField(T, "runtime") and @hasDecl(T, "Runtime") and
        @hasDecl(T.Runtime, "checkedInit");
}

pub const MethodMetadata = struct {
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

    fn init(allocator: std.mem.Allocator) @This() {
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
pub const ManagedTypeCache = struct {
    cache_arena: std.mem.Allocator,
    value_arena: std.mem.Allocator,
    io: std.Io,
    type_def_map: std.HashMap(
        api.sdk.TypeDefinition,
        TypeDefMetadata,
        TypeDefContext,
        std.hash_map.default_max_load_percentage,
    ),
    managed_metadata: std.StringHashMap(ManagedObjectMetadata),
    /// Should be read before resetting `value_arena`.
    diagnostics: std.ArrayList(u8),
    mutex: std.Io.Mutex = .init,

    const Self = @This();

    /// `cache_arena`: Used for caching type definitions, method and field metadata.
    /// It's expected to be reset rarely.
    ///
    /// `value_arena`: Used for temporary allocations when building method arguments or reading field values.
    /// It's expected to be reset often, ideally every frame, to avoid fragmentation and reduce memory usage.
    ///
    /// `io`: Used for locking when accessing the cache.
    pub fn init(cache_arena: std.mem.Allocator, value_arena: std.mem.Allocator, io: std.Io) Self {
        return .{
            .cache_arena = cache_arena,
            .value_arena = value_arena,
            .io = io,
            .type_def_map = .init(cache_arena),
            .managed_metadata = .init(cache_arena),
            .diagnostics = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        {
            var values_iter = self.type_def_map.valueIterator();
            while (values_iter.next()) |metadata| {
                var methods = metadata.methods.valueIterator();
                while (methods.next()) |method| {
                    method.deinit(self.cache_arena);
                }

                metadata.methods.deinit();
                metadata.fields.deinit();
            }
        }
        {
            var values_iter = self.managed_metadata.valueIterator();
            while (values_iter.next()) |metadata| {
                self.cache_arena.free(metadata.methods);
                self.cache_arena.free(metadata.fields);
            }
        }

        self.type_def_map.deinit();
        self.managed_metadata.deinit();
        self.diagnostics.deinit(self.value_arena);
        self.* = undefined;
    }

    pub fn ownDiagnostics(self: *Self) ![:0]const u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        return self.diagnostics.toOwnedSliceSentinel(self.value_arena, 0);
    }

    pub fn lock(self: *Self) !void {
        return self.mutex.lock(self.io);
    }

    pub fn unlock(self: *Self) void {
        return self.mutex.unlock(self.io);
    }

    pub fn getOrCacheMethodMetadata(
        self: *Self,
        sdk: api.VerifiedSdk(.{
            .method = sdk_managed_specs.method,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
        type_def: api.sdk.TypeDefinition,
        sig: [:0]const u8,
    ) !MethodMetadata {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const type_def_entry = try self.type_def_map.getOrPutValue(type_def, .init(self.cache_arena));

        const method_sig = sig;

        const method_cache_entry = try type_def_entry.value_ptr.methods.getOrPut(method_sig);
        const method_metadata = if (method_cache_entry.found_existing) blk: {
            break :blk method_cache_entry.value_ptr.*;
        } else blk: {
            errdefer type_def_entry.value_ptr.methods.removeByPtr(method_cache_entry.key_ptr);

            const handle = type_def.findMethod(.fromOther(sdk), method_sig) orelse {
                return error.MethodNotFound;
            };
            const new_method_metadata = try MethodMetadata.init(self.cache_arena, .fo(sdk), handle);
            method_cache_entry.value_ptr.* = new_method_metadata;
            break :blk new_method_metadata;
        };

        return method_metadata;
    }

    pub fn invokeMethod(
        self: *Self,
        obj: ?*anyopaque,
        method_metadata: MethodMetadata,
        comptime param_interops: anytype,
        comptime ret: anytype,
        comptime static: bool,
        sdk: api.VerifiedSdk(.{
            .method = sdk_managed_specs.method,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
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

        if (comptime static and isSafeMode()) {
            if (!method_metadata.handle.isStatic(.fo(sdk))) {
                return error.RequiresInstance;
            }
        }

        var built_args = try buildMethodArgs(@constCast(&sdk), self, method_metadata, args, param_interops);

        const managed: api.sdk.ManagedObject = .{ .raw = @ptrCast(@alignCast(obj)) };
        var invoke_res = try managed.invokeMethod(method_metadata.handle, .fo(sdk), &built_args);

        if (invoke_res.exception_thrown) {
            return error.ExceptionThrown;
        }

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

    pub fn callMethod(
        self: *Self,
        managed: api.sdk.ManagedObject,
        sig: [:0]const u8,
        comptime param_interops: anytype,
        comptime ret: anytype,
        sdk: api.VerifiedSdk(.{
            .method = sdk_managed_specs.method,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
        args: anytype,
    ) !ret.type {
        const type_def = managed.getTypeDefinition(.fo(sdk)) orelse return error.NoTypeDefFound;
        const method_metadata = try self.getOrCacheMethodMetadata(.fo(sdk), type_def, sig);
        return try self.invokeMethod(managed.raw, method_metadata, param_interops, ret, false, .fo(sdk), args);
    }

    pub fn getOrCacheFieldMetadata(
        self: *Self,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
        type_def: api.sdk.TypeDefinition,
        comptime field_data: anytype,
    ) !FieldMetadata {
        const field = comptime if (@TypeOf(field_data) == @EnumLiteral()) .{
            .name = @tagName(field_data),
        } else field_data;
        const FieldT = @TypeOf(field);
        if (!type_utils.isPureStruct(FieldT)) {
            @compileError("Please provide 'field_data' with 'name', 'get' fields or just @EnumLiteral with the field name.");
        }

        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const type_def_entry = try self.type_def_map.getOrPutValue(type_def, .init(self.cache_arena));

        const field_name = comptime field.name;

        const field_cache_entry = try type_def_entry.value_ptr.fields.getOrPut(field_name);

        const field_metadata: FieldMetadata = if (field_cache_entry.found_existing) blk: {
            break :blk field_cache_entry.value_ptr.*;
        } else blk: {
            errdefer type_def_entry.value_ptr.fields.removeByPtr(field_cache_entry.key_ptr);

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

        return field_metadata;
    }

    pub fn readField(
        self: *Self,
        obj: ?*anyopaque,
        field_metadata: FieldMetadata,
        comptime T: type,
        comptime interop: ?ToZigInterop(T),
        is_obj_valtype: bool,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
    ) !T {
        @setRuntimeSafety(false);

        const field_handle = field_metadata.handle;

        const data_read_ptr: *?*anyopaque = @ptrCast(@alignCast(field_handle.getDataRaw(
            .fo(sdk),
            obj,
            is_obj_valtype,
        )));

        const getInterop = interop orelse defaultToZigInterop(T);
        return getInterop(@constCast(&sdk), self, field_metadata.type_def, data_read_ptr);
    }

    pub fn writeField(
        self: *Self,
        obj: ?*anyopaque,
        field_metadata: FieldMetadata,
        comptime interop: ?FromZigInterop,
        is_obj_valtype: bool,
        comptime static: bool,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
        value: anytype,
    ) !void {
        @setRuntimeSafety(false);

        const is_valtype = field_metadata.type_def.getVmObjType(.fo(sdk)) == .valtype;

        const field_handle = field_metadata.handle;

        if (comptime static) {
            if (!field_handle.isStatic(.fo(sdk)) and !is_valtype) {
                return error.RequiresInstance;
            }
        }

        const data_write_ptr: *?*anyopaque = @ptrCast(@alignCast(field_handle.getDataRaw(
            .fo(sdk),
            obj,
            is_obj_valtype,
        )));

        const setInterop = interop orelse defaultFromZigInterop;
        return setInterop(@constCast(&sdk), self, field_metadata.type_def, value, data_write_ptr);
    }

    pub fn getFieldFromTypeDef(
        self: *Self,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
        type_def: api.sdk.TypeDefinition,
        obj: ?*anyopaque,
        comptime T: type,
        comptime field_data: anytype,
        comptime passed_managed_obj: bool,
    ) !T {
        const field = comptime if (@TypeOf(field_data) == @EnumLiteral()) .{
            .name = @tagName(field_data),
        } else field_data;
        const FieldT = @TypeOf(field);
        if (!type_utils.isPureStruct(FieldT)) {
            @compileError("Please provide 'field_data' with 'name', 'get' fields or just @EnumLiteral with the field name.");
        }

        const field_metadata = try self.getOrCacheFieldMetadata(.fo(sdk), type_def, field_data);

        const is_passed_type_valtype = type_def.getVmObjType(.fo(sdk)) == .valtype;

        const getInterop = if (@hasField(FieldT, "get"))
            field.get
        else
            defaultToZigInterop(T);

        return self.readField(
            obj,
            field_metadata,
            T,
            getInterop,
            is_passed_type_valtype and !passed_managed_obj,
            .fo(sdk),
        );
    }

    pub fn setFieldFromTypeDef(
        self: *Self,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
        type_def: api.sdk.TypeDefinition,
        obj: ?*anyopaque,
        comptime field_data: anytype,
        comptime passed_managed_obj: bool,
        comptime static: bool,
        value: anytype,
    ) !void {
        const field = comptime if (@TypeOf(field_data) == @EnumLiteral()) .{
            .name = @tagName(field_data),
        } else field_data;
        const FieldT = @TypeOf(field);

        const field_metadata = try self.getOrCacheFieldMetadata(.fo(sdk), type_def, field_data);

        const is_passed_type_valtype = type_def.getVmObjType(.fo(sdk)) == .valtype;

        const setInterop = if (@hasField(FieldT, "set"))
            field.set
        else
            defaultFromZigInterop;

        return self.writeField(
            obj,
            field_metadata,
            setInterop,
            is_passed_type_valtype and !passed_managed_obj,
            static,
            .fo(sdk),
            value,
        );
    }

    pub inline fn getField(
        self: *Self,
        managed: api.sdk.ManagedObject,
        comptime field_data: anytype,
        comptime T: type,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
    ) !T {
        const type_def = managed.getTypeDefinition(.fo(sdk)) orelse return error.NoTypeDefFound;
        return self.getFieldFromTypeDef(.fo(sdk), type_def, managed.raw, T, field_data, true);
    }

    pub inline fn setField(
        self: *Self,
        managed: api.sdk.ManagedObject,
        comptime field_data: anytype,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
        value: anytype,
    ) !void {
        const type_def = managed.getTypeDefinition(.fo(sdk)) orelse return error.NoTypeDefFound;
        return self.setFieldFromTypeDef(.fo(sdk), type_def, managed.raw, field_data, true, false, value);
    }

    pub fn callStaticMethod(
        self: *Self,
        managed_type_name: [:0]const u8,
        sig: [:0]const u8,
        comptime param_interops: anytype,
        comptime ret: anytype,
        sdk: api.VerifiedSdk(.{
            .method = sdk_managed_specs.method,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
            .functions = .{.get_tdb},
            .tdb = .find_type,
        }),
        args: anytype,
    ) !ret.type {
        const tdb = api.sdk.getTdb(.fo(sdk)) orelse return error.TdbNull;
        const type_def = tdb.findType(.fo(sdk), managed_type_name) orelse return error.NoTypeDefFound;
        const method_metadata = try self.getOrCacheMethodMetadata(.fo(sdk), type_def, sig);
        return try self.invokeMethod(null, method_metadata, param_interops, ret, true, .fo(sdk), args);
    }

    pub inline fn getStaticField(
        self: *Self,
        managed_type_name: [:0]const u8,
        comptime T: type,
        comptime field_data: anytype,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .type_definition = .all,
            .functions = .{.get_tdb},
            .tdb = .find_type,
        }),
    ) !T {
        const tdb = api.sdk.getTdb(.fo(sdk)) orelse return error.TdbNull;
        const type_def = tdb.findType(.fo(sdk), managed_type_name) orelse return error.NoTypeDefFound;
        return self.getFieldFromTypeDef(.fo(sdk), type_def, null, T, field_data, false);
    }

    pub inline fn setStaticField(
        self: *Self,
        managed_type_name: [:0]const u8,
        comptime field_data: anytype,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .type_definition = .all,
            .functions = .{.get_tdb},
            .tdb = .find_type,
        }),
        value: anytype,
    ) !void {
        const tdb = api.sdk.getTdb(.fo(sdk)) orelse return error.TdbNull;
        const type_def = tdb.findType(.fo(sdk), managed_type_name) orelse return error.NoTypeDefFound;
        return self.setFieldFromTypeDef(.fo(sdk), type_def, null, field_data, false, true, value);
    }

    pub fn appendDiagnostics(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        try self.diagnostics.print(self.value_arena, fmt ++ "\n", args);
    }

    fn appendError(self: *Self, err: []const u8) !void {
        try self.diagnostics.appendSlice(self.value_arena, err);
        try self.diagnostics.append(self.value_arena, '\n');
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
        .create_managed_string,
        .create_managed_string_normal,
    },
    .managed_object = .get_type_definition,
    .method = .{
        .invoke,
        .get_return_type,
        .get_num_params,
        .get_params,
        .is_static,
    },
    .field = .{
        .get_offset_from_base,
        .get_data_raw,
        .get_type,
        .is_static,
    },
    .type_definition = .all,
};

const ManagedSdk = api.VerifiedSdk(sdk_managed_specs);

const managed_object_runtime_size = api.sdk.ManagedObject.runtime_size;

pub const ValueType = struct {
    data: []align(@alignOf(*anyopaque)) u8,
    type_def: api.sdk.TypeDefinition,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, sdk: ManagedSdk, data: *?*anyopaque, type_def: api.sdk.TypeDefinition) !Self {
        @setRuntimeSafety(false);

        const data_p: [*]u8 = @ptrCast(@alignCast(data));
        const size = type_def.getValueTypeSize(.fo(sdk));
        const buf = try allocator.alignedAlloc(u8, .of(usize), managed_object_runtime_size + size);
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

    pub inline fn valuePtr(self: Self) ?*anyopaque {
        return @ptrCast(@alignCast(&self.data[managed_object_runtime_size]));
    }

    pub inline fn call(
        self: Self,
        comptime sig: [:0]const u8,
        comptime param_interops: anytype,
        comptime ret: anytype,
        cache: *ManagedTypeCache,
        sdk: api.VerifiedSdk(.{
            .method = sdk_managed_specs.method,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
        args: anytype,
    ) !ret.type {
        const method_metadata = try cache.getOrCacheMethodMetadata(.fo(sdk), self.type_def, sig);
        return try cache.invokeMethod(
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
        comptime field_data: anytype,
        comptime T: type,
        cache: *ManagedTypeCache,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
    ) !T {
        return cache.getFieldFromTypeDef(
            .fo(sdk),
            self.type_def,
            self.valuePtr(),
            T,
            field_data,
            false,
        );
    }

    pub inline fn set(
        self: Self,
        comptime field_data: anytype,
        cache: *ManagedTypeCache,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
        value: anytype,
    ) !void {
        return cache.setFieldFromTypeDef(
            .fo(sdk),
            self.type_def,
            self.valuePtr(),
            field_data,
            false,
            false,
            value,
        );
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

pub const ValueTypeView = struct {
    data: *?*anyopaque,
    type_def: api.sdk.TypeDefinition,

    const Self = @This();

    pub inline fn boxed(self: Self, allocator: std.mem.Allocator, sdk: ManagedSdk) !ValueType {
        return try ValueType.init(allocator, sdk, self.data, self.type_def);
    }

    pub inline fn valuePtr(self: Self) ?*anyopaque {
        return @ptrCast(self.data);
    }

    pub inline fn get(
        self: Self,
        comptime field_data: anytype,
        comptime T: type,
        cache: *ManagedTypeCache,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
    ) !T {
        return cache.getFieldFromTypeDef(
            .fo(sdk),
            self.type_def,
            self.valuePtr(),
            T,
            field_data,
            false,
        );
    }

    pub inline fn set(
        self: Self,
        comptime field_data: anytype,
        cache: *ManagedTypeCache,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
        value: anytype,
    ) !void {
        return cache.setFieldFromTypeDef(
            .fo(sdk),
            self.type_def,
            self.valuePtr(),
            field_data,
            false,
            false,
            value,
        );
    }
};

pub const SystemStringView = struct {
    data: [:0]const u16,
};

pub const FromZigInterop = fn (
    userdata: ?*anyopaque,
    cache: *ManagedTypeCache,
    to_type_def: api.sdk.TypeDefinition,
    arg: anytype,
    out: *?*anyopaque,
) anyerror!void;

pub fn ToZigInterop(comptime T: type) type {
    return fn (
        userdata: ?*anyopaque,
        cache: *ManagedTypeCache,
        from_type_def: api.sdk.TypeDefinition,
        data: *?*anyopaque,
    ) anyerror!T;
}

// TODO: Implement more cases:
// https://github.com/praydog/REFramework/blob/ea66d322fbe2ebb7e2efd8fd6aa6b06779da6f76/src/mods/bindings/Sdk.cpp#L1086
pub fn defaultFromZigInterop(
    userdata: ?*anyopaque,
    cache: *ManagedTypeCache,
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
            const managed_string = api.sdk.createManagedStringNormal(.fo(sdk), arg) orelse return error.FailedToCreateString;
            out.* = @ptrCast(managed_string.raw);
            return;
        },
        [:0]u8 => {
            const managed_string = api.sdk.createManagedStringNormal(.fo(sdk), arg) orelse return error.FailedToCreateString;
            out.* = @ptrCast(managed_string.raw);
            return;
        },
        [*:0]const u8 => {
            const managed_string = api.sdk.createManagedStringNormal(.fo(sdk), std.mem.span(arg)) orelse return error.FailedToCreateString;
            out.* = @ptrCast(managed_string.raw);
            return;
        },
        [:0]const u16 => {
            const managed_string = api.sdk.createManagedString(.fo(sdk), arg) orelse return error.FailedToCreateString;
            out.* = @ptrCast(managed_string.raw);
            return;
        },
        [:0]u16 => {
            const managed_string = api.sdk.createManagedString(.fo(sdk), arg) orelse return error.FailedToCreateString;
            out.* = @ptrCast(managed_string.raw);
            return;
        },
        [*:0]const u16 => {
            const managed_string = api.sdk.createManagedString(.fo(sdk), std.mem.span(arg)) orelse return error.FailedToCreateString;
            out.* = @ptrCast(managed_string.raw);
            return;
        },
        SystemStringView => {
            return defaultFromZigInterop(userdata, cache, to_type_def, arg.data, out);
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
            return defaultFromZigInterop(userdata, cache, to_type_def, enum_val, out);
        },
        .@"struct" => {
            @compileError("Cannot interop zig struct");
        },
        .optional => |o| {
            if (@typeInfo(o.child) != .@"struct" and @typeInfo(o.child) != .pointer) {
                @compileError("Option struct and pointer types are the only supported optional types. Found: '" ++ @typeName(ArgT) ++ "'");
            }

            if (arg) |v| {
                try defaultFromZigInterop(userdata, cache, to_type_def, v, out);
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

inline fn systemStrPtr(
    type_def: api.sdk.TypeDefinition,
    managed: api.sdk.ManagedObject,
    sdk: ManagedSdk,
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

pub const SystemArrayEntries = struct {
    ptr: ?*anyopaque,
    len: usize,
    contained_type_def: api.sdk.TypeDefinition,

    pub inline fn unsafe(managed: api.sdk.ManagedObject, sdk: ManagedSdk) SystemArrayEntries {
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

// TODO: Implement more cases:
// https://github.com/praydog/REFramework/blob/ea66d322fbe2ebb7e2efd8fd6aa6b06779da6f76/src/mods/bindings/Sdk.cpp#L927
pub fn defaultToZigInterop(RetType: type) fn (?*anyopaque, *ManagedTypeCache, api.sdk.TypeDefinition, *?*anyopaque) anyerror!RetType {
    return struct {
        fn func(
            userdata: ?*anyopaque,
            cache: *ManagedTypeCache,
            from_type_def: api.sdk.TypeDefinition,
            data: *?*anyopaque,
        ) anyerror!RetType {
            @setRuntimeSafety(false);
            // _ = from_type_def;
            if (RetType == void) return {};

            const sdk_ptr: *ManagedSdk = @ptrCast(@alignCast(userdata));
            const sdk = sdk_ptr.*;

            switch (RetType) {
                []const u8, []u8 => {
                    @compileError("Please consider using SystemStringView type, and later convert it to u8 your own way.");
                },
                [:0]u16 => {
                    return (try defaultToZigInterop(SystemStringView)).data;
                },
                [*:0]u16 => {
                    return (try defaultToZigInterop(SystemStringView)).data.ptr;
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
                    const wchars: [*:0]const u16 = @ptrCast(@alignCast(systemStrPtr(
                        from_type_def,
                        managed_ret_val,
                        .fo(sdk),
                    ) orelse return error.FailedToGetStringData));

                    return .{ .data = std.mem.span(wchars) };
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
                    return try ValueType.init(cache.value_arena, sdk, data, from_type_def);
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
                return try RetType.init(cache, sdk, obj);
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
                    return @enumFromInt(try defaultToZigInterop(EnumUnderlyingT)(userdata, cache, from_type_def, data));
                },
                .optional => |o| {
                    if (@typeInfo(o.child) != .@"struct" and @typeInfo(o.child) != .pointer) {
                        @compileError("Option struct and pointer types are the only supported optional types for return values. Found: '" ++ @typeName(RetType) ++ "'");
                    }
                    const ptr: ?*anyopaque = data.*;
                    if (ptr == null) return null;

                    return try defaultToZigInterop(o.child)(userdata, cache, from_type_def, data);
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

inline fn anyParamUnknown(comptime params: anytype) bool {
    const params_len = std.meta.fields(@TypeOf(params)).len;
    inline for (0..params_len) |j| {
        const param = @field(params, std.fmt.comptimePrint("{d}", .{j}));
        const info = @typeInfo(@TypeOf(param.type_name));
        if (info == .null or info == .undefined) {
            return true;
        }
    }
    return false;
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

inline fn buildMethodSignature(comptime method_name: [:0]const u8, comptime params: anytype) [:0]const u8 {
    return comptime blk: {
        if (!type_utils.isTuple(@TypeOf(params))) {
            @compileError("'" ++ method_name ++ "' method's params are not tuple type. Need something like: .params = .{ .{ .type_name = \"\", .type = ... } }");
        }
        if (anyParamUnknown(params)) {
            break :blk method_name;
        } else {
            const params_len = std.meta.fields(@TypeOf(params)).len;

            var sig: [:0]const u8 = method_name ++ "(";
            if (params_len > 0) {
                sig = std.fmt.comptimePrint("{s}{s}", .{ sig, params.@"0".type_name });
                for (1..params_len) |i| {
                    sig = std.fmt.comptimePrint("{s}, {s}", .{ sig, @field(params, std.fmt.comptimePrint("{d}", .{i})).type_name });
                }
            }
            sig = std.fmt.comptimePrint("{s})", .{sig});
            break :blk sig;
        }
    };
}

fn buildMethodArgsFromData(
    Data: type,
    userdata: ?*anyopaque,
    cache: *ManagedTypeCache,
    method_metadata: MethodMetadata,
    args: anytype,
) anyerror![std.meta.fields(@TypeOf(args)).len]?*anyopaque {
    const args_len = std.meta.fields(@TypeOf(args)).len;
    if (anyParamUnknown(Data.get().params)) {
        if (comptime isSafeMode()) {
            // TODO: Check for type interopability
            if (method_metadata.param_type_defs.len != args_len) {
                return error.InvalidArgsLength;
            }
        }
    } else {
        const params_len = Data.getParamsLen();

        if (params_len != args_len) {
            @compileError(std.fmt.comptimePrint("Expected args len: {d}, found: {d}", .{ params_len, args_len }));
        }
    }

    comptime var param_interops: [args_len]FromZigInterop = undefined;
    inline for (0..args_len) |i| {
        param_interops[i] = Data.getParam(i).interop;
    }

    return buildMethodArgsImpl(userdata, cache, method_metadata, args, param_interops);
}

fn buildMethodArgsImpl(
    userdata: ?*anyopaque,
    cache: *ManagedTypeCache,
    method_metadata: MethodMetadata,
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
                userdata,
                cache,
                method_metadata.param_type_defs[i],
                arg,
                &out[i],
            );
        }
    }

    return out;
}

pub inline fn buildMethodArgs(
    userdata: ?*anyopaque,
    cache: *ManagedTypeCache,
    method_metadata: MethodMetadata,
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

    return buildMethodArgsImpl(userdata, cache, method_metadata, args, param_interop_fns);
}

fn FieldData(comptime Owner: type, comptime fields: anytype, comptime field: @EnumLiteral()) type {
    const field_names = std.meta.fieldNames(@TypeOf(fields));
    inline for (field_names, 0..) |field_name, i| {
        if (std.mem.eql(u8, field_name, @tagName(field))) {
            return struct {
                const Data = @TypeOf(@field(fields, @tagName(field)));
                const Type = if (@TypeOf(get().type) == @EnumLiteral() and get().type == .self) Owner else get().type;
                const DefaultInterop = DefaultFieldInterop(Type);
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

fn DefaultFieldInterop(FieldType: type) type {
    return struct {
        inline fn get(
            userdata: ?*anyopaque,
            cache: *ManagedTypeCache,
            from_type_def: api.sdk.TypeDefinition,
            field_raw_data: *?*anyopaque,
        ) anyerror!FieldType {
            // TODO: Add more safety fences?
            return defaultToZigInterop(FieldType)(userdata, cache, from_type_def, field_raw_data);
        }

        inline fn set(
            userdata: ?*anyopaque,
            cache: *ManagedTypeCache,
            to_type_def: api.sdk.TypeDefinition,
            value: FieldType,
            write_ptr: *?*anyopaque,
        ) anyerror!void {
            return defaultFromZigInterop(userdata, cache, to_type_def, value, write_ptr);
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
///         .interop: ToZigInterop(type) = defaultToZigInterop(ret.type),
///     },
///     params: []const MethodParam,
/// };
/// const MethodParam = struct {
///     // if any one of the params has type_name set to null or undefined, the signature will be built without type names.
///     type_name: ?[:0]const u8,
///     type: type,
///     comptime interop: FromZigInterop = defaultFromZigInterop,
/// };
/// fields = .{
///     .@"field name": Field,
/// }
/// const Field = struct {
///     type: type,
///     comptime get: ToZigInterop(type) = defaultToZigInterop(type),
///     comptime set: FromZigInterop = defaultFromZigInterop,
/// };
pub fn ManagedObject(
    comptime full_type_name: [:0]const u8,
    comptime methods: anytype,
    comptime fields: anytype,
) type {
    const ManagedObjectType = struct {
        metadata: ManagedObjectMetadata,
        cache: *ManagedTypeCache,

        const ManagedObjectType = @This();

        pub const Instance = struct {
            managed: api.sdk.ManagedObject,
            runtime: Runtime,

            const Self = @This();
            pub const Runtime = ManagedObjectType;

            pub fn init(cache: *ManagedTypeCache, sdk: ManagedSdk, managed: api.sdk.ManagedObject) !Self {
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
                var built_args = try buildMethodArgsFromData(Data, @constCast(&sdk), self.runtime.cache, method_metadata, args);

                var invoke_res = try self.managed.invokeMethod(method_metadata.handle, .fo(sdk), &built_args);

                if (invoke_res.exception_thrown) {
                    return error.ExceptionThrown;
                }

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
            ) !FieldData(Instance, fields, field).Type {
                @setRuntimeSafety(false);
                const Data = FieldData(Instance, fields, field);

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
                value: FieldData(Instance, fields, field).Type,
            ) !void {
                @setRuntimeSafety(false);
                const Data = FieldData(Instance, fields, field);

                const field_metadata = self.runtime.metadata.fields[Data.getIndex()];
                const field_handle = field_metadata.handle;

                const data_write_ptr: *?*anyopaque = @ptrCast(@alignCast(field_handle.getDataRaw(
                    .fo(sdk),
                    self.managed.raw,
                    false,
                )));
                try Data.getSetInterop()(
                    @constCast(&sdk),
                    self.runtime.cache,
                    field_metadata.type_def,
                    value,
                    data_write_ptr,
                );
            }

            pub inline fn callStatic(
                self: Self,
                comptime method: @EnumLiteral(),
                sdk: ManagedSdk,
                args: anytype,
            ) !getMethodData(methods, method).RetType() {
                return self.runtime.callStatic(method, sdk, args);
            }

            pub inline fn getStatic(
                self: Self,
                comptime field: @EnumLiteral(),
                sdk: ManagedSdk,
            ) !FieldData(Instance, fields, field).Type {
                @setRuntimeSafety(false);
                return self.runtime.getStatic(field, sdk);
            }

            pub inline fn setStatic(
                self: Self,
                comptime field: @EnumLiteral(),
                sdk: ManagedSdk,
                value: FieldData(Instance, fields, field).Type,
            ) !void {
                return self.runtime.setStatic(field, sdk, value);
            }

            pub inline fn fullTypeName() [:0]const u8 {
                return full_type_name;
            }
        };

        pub fn get(cache: *ManagedTypeCache, sdk: ManagedSdk.Extend(.{
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

        pub fn getWithTdb(cache: *ManagedTypeCache, sdk: ManagedSdk.Extend(.{ .tdb = .find_type }), tdb: api.sdk.Tdb) !ManagedObjectType {
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

        pub fn callStatic(
            self: ManagedObjectType,
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

            const method_metadata = self.metadata.methods[Data.getIndex()];

            if (comptime isSafeMode()) {
                if (!method_metadata.handle.isStatic(.fo(sdk))) {
                    return error.NotStaticMethod;
                }
            }

            // doesn't matter if the "sdk" value gets modified, it will get discarded.
            var built_args = try buildMethodArgsFromData(Data, @constCast(&sdk), self.cache, method_metadata, args);

            var invoke_res = try method_metadata.handle.invoke(.fo(sdk), null, &built_args);

            if (invoke_res.exception_thrown) {
                return error.ExceptionThrown;
            }

            const p: *?*anyopaque = @ptrCast(@alignCast(&invoke_res.bytes[0]));
            if (!@hasField(@TypeOf(method_data), "ret")) {
                return try defaultToZigInterop(void)(
                    @constCast(&sdk),
                    self.cache,
                    method_metadata.ret_type_def,
                    p,
                );
            } else {
                // https://github.com/praydog/REFramework/blob/63dd83ead22bbab924b93bbd32e5be36d3a09a4d/src/mods/bindings/Sdk.cpp#L960
                // TODO: Use type full name?
                if (method_data.ret.type == f32 and !@hasField(@TypeOf(method_data.ret), "interop")) {
                    return @floatCast(try defaultToZigInterop(f64)(
                        @constCast(&sdk),
                        self.cache,
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
                        self.cache,
                        method_metadata.ret_type_def,
                        p,
                    );
                }
            }
        }

        pub fn getStatic(
            self: ManagedObjectType,
            comptime field: @EnumLiteral(),
            sdk: ManagedSdk,
        ) !FieldData(Instance, fields, field).Type {
            @setRuntimeSafety(false);
            const Data = FieldData(Instance, fields, field);

            const field_metadata = self.metadata.fields[Data.getIndex()];
            const field_handle = field_metadata.handle;

            if (comptime isSafeMode()) {
                const is_valtype = field_metadata.type_def.getVmObjType(.fo(sdk)) == .valtype;
                if (!field_handle.isStatic(.fo(sdk)) and !is_valtype) {
                    return error.InvalidStaticField;
                }
            }

            const data_read_ptr: *?*anyopaque = @ptrCast(@alignCast(field_handle.getDataRaw(
                .fo(sdk),
                null,
                false,
            )));
            return try Data.getGetInterop()(
                @constCast(&sdk),
                self.cache,
                field_metadata.type_def,
                data_read_ptr,
            );
        }

        pub fn setStatic(
            self: ManagedObjectType,
            comptime field: @EnumLiteral(),
            sdk: ManagedSdk,
            value: FieldData(Instance, fields, field).Type,
        ) !void {
            @setRuntimeSafety(false);
            const Data = FieldData(Instance, fields, field);

            const field_metadata = self.metadata.fields[Data.getIndex()];
            const field_handle = field_metadata.handle;

            if (comptime isSafeMode()) {
                const is_valtype = field_metadata.type_def.getVmObjType(.fo(sdk)) == .valtype;

                if (!field_handle.isStatic(.fo(sdk)) and !is_valtype) {
                    return error.InvalidStaticField;
                }
            }

            const data_write_ptr: *?*anyopaque = @ptrCast(@alignCast(field_handle.getDataRaw(
                .fo(sdk),
                null,
                false,
            )));
            try Data.getSetInterop()(
                @constCast(&sdk),
                self.cache,
                field_metadata.type_def,
                value,
                data_write_ptr,
            );
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

        fn checkedInit(cache: *ManagedTypeCache, sdk: ManagedSdk, managed: api.sdk.ManagedObject) !Instance {
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

        fn checkedRuntime(cache: *ManagedTypeCache, sdk: ManagedSdk, type_def: api.sdk.TypeDefinition) !ManagedObjectType {
            const method_names = comptime std.meta.fieldNames(@TypeOf(methods));
            var collected_methods = try std.ArrayList(MethodMetadata).initCapacity(cache.cache_arena, method_names.len);
            defer collected_methods.deinit(cache.cache_arena);

            const field_names = comptime std.meta.fieldNames(@TypeOf(fields));
            var collected_fields = try std.ArrayList(FieldMetadata).initCapacity(cache.cache_arena, field_names.len);
            defer collected_fields.deinit(cache.cache_arena);
            {
                try cache.lock();
                defer cache.unlock();

                // getting existing cached type_def metadata...
                const type_def_entry = try cache.type_def_map.getOrPutValue(type_def, .init(cache.cache_arena));

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
                            cache.cache_arena,
                            method_cache_entry.value_ptr.*,
                        );
                    } else {
                        // if we're removing on error, why not just not insert until we know it's valid?
                        // because it's a cold path, meaning these errors should happen rarely. otherwise,
                        // it's a user use case issue, they should be aware of what is available and what not.
                        errdefer type_def_entry.value_ptr.methods.removeByPtr(method_cache_entry.key_ptr);

                        const method = type_def.findMethod(.fromOther(sdk), method_sig) orelse {
                            cache.appendError("'" ++ method_sig ++ "' was not found in '" ++ full_type_name ++ "'") catch {};
                            return error.MethodNotFound;
                        };
                        // Disclaimer: Deiniting one of them is enough to free all
                        // the resources associated with it, make sure to call deinit
                        // once during one of the map/list owner free.
                        const new_method_metadata = try MethodMetadata.init(cache.cache_arena, .fo(sdk), method);
                        method_cache_entry.value_ptr.* = new_method_metadata;
                        try collected_methods.append(
                            cache.cache_arena,
                            new_method_metadata,
                        );
                    }
                }

                // Checking fields
                inline for (field_names) |field_name| {
                    // TODO: Check field Types for interoperability.
                    const field_cache_entry = try type_def_entry.value_ptr.fields.getOrPut(field_name);

                    if (field_cache_entry.found_existing) {
                        try collected_fields.append(cache.cache_arena, field_cache_entry.value_ptr.*);
                    } else {
                        errdefer type_def_entry.value_ptr.fields.removeByPtr(field_cache_entry.key_ptr);

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
                        try collected_fields.append(cache.cache_arena, new_field_metadata);
                    }
                }
            }

            const metadata = ManagedObjectMetadata{
                .type_def = type_def,
                .methods = try collected_methods.toOwnedSlice(cache.cache_arena),
                .fields = try collected_fields.toOwnedSlice(cache.cache_arena),
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

    var dummy_cache: ManagedTypeCache = .init(std.testing.allocator, std.testing.io);
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
        try defaultFromZigInterop(&dummy_sdk, &dummy_cache, dummy_typedef, 420, @ptrCast(@alignCast(&arg)));
        try std.testing.expectEqual(420, arg);
    }
}
