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

const invalid_offset: u32 = std.math.maxInt(u32);

// https://github.com/praydog/REFramework/blob/ce9df1fe81e897c117d85ac9c4446a1a453b938f/shared/sdk/RETypeDefinition.cpp#L434
pub const FieldMetadata = struct {
    handle: api.sdk.Field,
    type_def: api.sdk.TypeDefinition,
    offset: u32 = invalid_offset,
};

pub const ManagedObjectMetadata = struct {
    // They store TypeDefinition in a global map meaning it's almost like a static storage...
    // https://github.com/praydog/REFramework/blob/ce9df1fe81e897c117d85ac9c4446a1a453b938f/shared/sdk/RETypeDB.cpp#L20
    type_def: api.sdk.TypeDefinition,
    methods: []*MethodMetadata,
    fields: []*FieldMetadata,
};

pub const TypeDefMetadata = struct {
    methods: std.StringHashMap(*MethodMetadata),
    fields: std.StringHashMap(*FieldMetadata),
    def: api.sdk.TypeDefinition,

    fn init(allocator: std.mem.Allocator, def: api.sdk.TypeDefinition) @This() {
        return .{ .methods = .init(allocator), .fields = .init(allocator), .def = def };
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

/// A cache for managed type metadata, which is used to avoid redundant string allocations
/// and comparisons when accessing managed type metadata and invoking methods or accessing fields.
pub const ManagedTypeCache = struct {
    cache_arena: std.heap.ArenaAllocator,
    value_arena: std.heap.ArenaAllocator,
    io: std.Io,
    type_def_map: std.HashMapUnmanaged(
        api.sdk.TypeDefinition,
        *TypeDefMetadata,
        TypeDefContext,
        std.hash_map.default_max_load_percentage,
    ),
    /// Should be collected before any other interop calls.
    diagnostics: std.ArrayList(u8),
    mutex: std.Io.Mutex = .init,

    const Self = @This();

    /// `allocator`: GPA
    ///
    /// `io`: Used for locking when accessing the cache.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .cache_arena = .init(allocator),
            .value_arena = .init(allocator),
            .io = io,
            .type_def_map = .empty,
            .diagnostics = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        // {
        //     var values_iter = self.type_def_map.valueIterator();
        //     while (values_iter.next()) |metadata| {
        //         var methods = metadata.methods.valueIterator();
        //         while (methods.next()) |method| {
        //             method.deinit(self.cache_arena);
        //         }

        //         metadata.methods.deinit();
        //         metadata.fields.deinit();
        //     }
        // }

        self.type_def_map.deinit(self.cache_arena.allocator());
        self.diagnostics.deinit(self.value_arena.allocator());

        _ = self.cache_arena.reset(.free_all);
        _ = self.value_arena.reset(.free_all);

        self.* = undefined;
    }

    pub fn ownDiagnostics(self: *Self) ![:0]const u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        return self.diagnostics.toOwnedSliceSentinel(self.value_arena.allocator(), 0);
    }

    pub fn lock(self: *Self) !void {
        return self.mutex.lock(self.io);
    }

    pub fn unlock(self: *Self) void {
        return self.mutex.unlock(self.io);
    }

    pub fn newScope(self: *Self, allocator: std.mem.Allocator) Scope {
        return .init(allocator, self);
    }

    fn getOrCacheTypeDefMetadata(
        self: *Self,
        type_def: api.sdk.TypeDefinition,
    ) !*TypeDefMetadata {
        const arena = self.cache_arena.allocator();

        const type_def_entry = try self.type_def_map.getOrPut(arena, type_def);
        if (!type_def_entry.found_existing) {
            const type_def_metadata = try arena.create(TypeDefMetadata);
            type_def_metadata.* = TypeDefMetadata.init(arena, type_def);
            type_def_entry.value_ptr.* = type_def_metadata;
        }

        return type_def_entry.value_ptr.*;
    }

    fn getOrCacheMethodMetadataTo(
        self: *Self,
        type_def_metadata: *TypeDefMetadata,
        sig: [:0]const u8,
        sdk: api.VerifiedSdk(.{
            .method = sdk_managed_specs.method,
            .type_definition = .all,
        }),
    ) !*MethodMetadata {
        const arena = self.cache_arena.allocator();

        const method_sig = sig;

        const method_cache_entry = try type_def_metadata.*.methods.getOrPut(method_sig);
        const method_metadata = if (method_cache_entry.found_existing) blk: {
            break :blk method_cache_entry.value_ptr.*;
        } else blk: {
            errdefer type_def_metadata.*.methods.removeByPtr(method_cache_entry.key_ptr);

            const type_def = type_def_metadata.def;

            const handle = type_def.findMethod(.fromOther(sdk), method_sig) orelse {
                return error.MethodNotFound;
            };

            const new_method_metadata = try arena.create(MethodMetadata);
            new_method_metadata.* = try MethodMetadata.init(arena, .fo(sdk), handle);

            method_cache_entry.value_ptr.* = new_method_metadata;
            break :blk new_method_metadata;
        };

        return method_metadata;
    }

    fn getOrCacheFieldMetadataTo(
        self: *Self,
        type_def_metadata: *TypeDefMetadata,
        field_name: [:0]const u8,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .type_definition = .all,
        }),
    ) !*FieldMetadata {
        const arena = self.cache_arena.allocator();

        const field_cache_entry = try type_def_metadata.*.fields.getOrPut(field_name);

        const field_metadata: *FieldMetadata = if (field_cache_entry.found_existing) blk: {
            break :blk field_cache_entry.value_ptr.*;
        } else blk: {
            errdefer type_def_metadata.*.fields.removeByPtr(field_cache_entry.key_ptr);

            const type_def = type_def_metadata.def;

            const field_handle = type_def.findField(.fo(sdk), field_name) orelse {
                return error.FieldNotFound;
            };
            const field_type_def = field_handle.getType(.fo(sdk)) orelse {
                return error.FieldInvalidType;
            };

            const new_field_metadata = try arena.create(FieldMetadata);
            new_field_metadata.* = .{
                .handle = field_handle,
                .type_def = field_type_def,
            };

            field_cache_entry.value_ptr.* = new_field_metadata;
            break :blk new_field_metadata;
        };

        return field_metadata;
    }

    pub inline fn getOrCacheMethodMetadata(
        self: *Self,
        sdk: api.VerifiedSdk(.{
            .method = sdk_managed_specs.method,
            .type_definition = .all,
        }),
        type_def: api.sdk.TypeDefinition,
        sig: [:0]const u8,
    ) !*MethodMetadata {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const type_def_metadata = try self.getOrCacheTypeDefMetadata(type_def);
        return self.getOrCacheMethodMetadataTo(type_def_metadata, sig, .fo(sdk));
    }

    pub inline fn getOrCacheFieldMetadata(
        self: *Self,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .type_definition = .all,
        }),
        type_def: api.sdk.TypeDefinition,
        field_name: [:0]const u8,
    ) !*FieldMetadata {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const type_def_metadata = try self.getOrCacheTypeDefMetadata(type_def);
        return self.getOrCacheFieldMetadataTo(type_def_metadata, field_name, .fo(sdk));
    }

    pub fn appendDiagnostics(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        try self.diagnostics.print(self.value_arena, fmt ++ "\n", args);
    }

    /// Resolves a managed type by its name and returns its metadata, it will cache the required "metadata"
    /// so calling it with same type name will be faster after the first call.
    pub inline fn resolve(
        self: *Self,
        comptime type_name: [:0]const u8,
        tdb: api.sdk.Tdb,
        sdk: api.VerifiedSdk(.{ .tdb = .find_type }),
    ) !ResolvedType(type_name) {
        return .init(self, tdb, .fo(sdk));
    }

    fn appendError(self: *Self, err: []const u8) !void {
        const arena = self.value_arena.allocator();
        try self.diagnostics.appendSlice(arena, err);
        try self.diagnostics.append(arena, '\n');
    }
};

/// Should be used for scoped access to cached metadata and interop functions.
/// Not thread safe, should be created and used within the same thread, but multiple
/// scopes can exist at the same time.
pub const Scope = struct {
    cache: *ManagedTypeCache,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, cache: *ManagedTypeCache) Scope {
        return .{
            .cache = cache,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn reset(self: *Scope) void {
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn deinit(self: *Scope) void {
        self.arena.deinit();
    }

    pub fn invokeMethod(
        self: *Scope,
        obj: ?*anyopaque,
        method_metadata: *MethodMetadata,
        comptime param_interops: anytype,
        comptime ret: anytype,
        comptime static: bool,
        sdk: api.VerifiedSdk(.{
            .method = sdk_managed_specs.method,
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
        var invoke_res: api.InvokeRet = .{};
        try managed.invokeMethod(method_metadata.handle, .fo(sdk), &built_args, &invoke_res);

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

    pub fn readField(
        self: *Scope,
        obj: ?*anyopaque,
        field_metadata: *FieldMetadata,
        comptime T: type,
        comptime interop: ?ToZigInterop(T),
        is_obj_valtype: bool,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
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
        self: *Scope,
        obj: ?*anyopaque,
        field_metadata: *FieldMetadata,
        comptime interop: ?FromZigInterop,
        is_obj_valtype: bool,
        comptime static: bool,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
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
        self: *Scope,
        obj: ?*anyopaque,
        type_def: api.sdk.TypeDefinition,
        field_name: [:0]const u8,
        comptime T: type,
        comptime interop: ?ToZigInterop(T),
        comptime passed_managed_obj: bool,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .type_definition = .all,
        }),
    ) !T {
        // const field = comptime if (@TypeOf(field_data) == @EnumLiteral()) .{
        //     .name = @tagName(field_data),
        // } else field_data;
        // const FieldT = @TypeOf(field);
        // if (!type_utils.isPureStruct(FieldT)) {
        //     @compileError("Please provide 'field_data' with 'name', 'get' fields or just @EnumLiteral with the field name.");
        // }

        const field_metadata = try self.cache.getOrCacheFieldMetadata(.fo(sdk), type_def, field_name);

        const is_passed_type_valtype = type_def.getVmObjType(.fo(sdk)) == .valtype;

        return self.readField(
            obj,
            field_metadata,
            T,
            interop,
            is_passed_type_valtype and !passed_managed_obj,
            .fo(sdk),
        );
    }

    pub fn setFieldFromTypeDef(
        self: *Scope,
        obj: ?*anyopaque,
        type_def: api.sdk.TypeDefinition,
        field_name: [:0]const u8,
        comptime interop: ?FromZigInterop,
        comptime passed_managed_obj: bool,
        comptime static: bool,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .type_definition = .all,
        }),
        value: anytype,
    ) !void {
        // const field = comptime if (@TypeOf(field_data) == @EnumLiteral()) .{
        //     .name = @tagName(field_data),
        // } else field_data;
        // const FieldT = @TypeOf(field);

        const field_metadata = try self.cache.getOrCacheFieldMetadata(.fo(sdk), type_def, field_name);

        const is_passed_type_valtype = type_def.getVmObjType(.fo(sdk)) == .valtype;

        return self.writeField(
            obj,
            field_metadata,
            interop,
            is_passed_type_valtype and !passed_managed_obj,
            static,
            .fo(sdk),
            value,
        );
    }

    pub inline fn callMethod(
        self: *Scope,
        managed: api.sdk.ManagedObject,
        sig: [:0]const u8,
        comptime RetType: type,
        sdk: api.VerifiedSdk(.{
            .method = sdk_managed_specs.method,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
        args: anytype,
    ) !RetType {
        return self.callMethodWithInterops(managed, sig, .{}, RetType, null, .fo(sdk), args);
    }

    /// Accepts param interops and return interop, which allows you to control how parameters
    /// and return value are marshaled between Zig and the managed environment.
    ///
    /// If you just want to interop RetType, you can pass empty struct for param_interops and provide
    /// interop for RetType in rInterop.
    ///
    /// If you just want to interop parameters, you can provide interops for parameters, and `rInterop`
    /// as null.
    pub inline fn callMethodWithInterops(
        self: *Scope,
        managed: api.sdk.ManagedObject,
        sig: [:0]const u8,
        comptime param_interops: anytype,
        comptime RetType: type,
        comptime rInterop: ?ToZigInterop(RetType),
        sdk: api.VerifiedSdk(.{
            .method = sdk_managed_specs.method,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
        args: anytype,
    ) !RetType {
        const type_def = managed.getTypeDefinition(.fo(sdk)) orelse return error.NoTypeDefFound;
        const method_metadata = try self.cache.getOrCacheMethodMetadata(.fo(sdk), type_def, sig);
        const retInterop = comptime rInterop orelse defaultToZigInterop(RetType);
        return try self.invokeMethod(
            managed.raw,
            method_metadata,
            param_interops,
            .{ .type = RetType, .interop = retInterop },
            false,
            .fo(sdk),
            args,
        );
    }

    pub fn callStaticMethod(
        self: *Scope,
        managed_type_name: [:0]const u8,
        sig: [:0]const u8,
        comptime RetType: type,
        sdk: api.VerifiedSdk(.{
            .method = sdk_managed_specs.method,
            .type_definition = .all,
            .functions = .get_tdb,
            .tdb = .find_type,
        }),
        args: anytype,
    ) !RetType {
        return self.callStaticMethodWithInterops(managed_type_name, sig, .{}, RetType, null, .fo(sdk), args);
    }

    /// Same as `callMethodWithInterops` but for static methods, see its documentation for details.
    pub inline fn callStaticMethodWithInterops(
        self: *Scope,
        managed_type_name: [:0]const u8,
        sig: [:0]const u8,
        comptime param_interops: anytype,
        comptime RetType: type,
        comptime rInterop: ?ToZigInterop(RetType),
        sdk: api.VerifiedSdk(.{
            .method = sdk_managed_specs.method,
            .type_definition = .all,
            .functions = .get_tdb,
            .tdb = .find_type,
        }),
        args: anytype,
    ) !RetType {
        const tdb = api.sdk.getTdb(.fo(sdk)) orelse return error.TdbNull;
        const type_def = tdb.findType(.fo(sdk), managed_type_name) orelse return error.NoTypeDefFound;
        const method_metadata = try self.cache.getOrCacheMethodMetadata(.fo(sdk), type_def, sig);
        const retInterop = comptime rInterop orelse defaultToZigInterop(RetType);
        return try self.invokeMethod(
            null,
            method_metadata,
            param_interops,
            .{ .type = RetType, .interop = retInterop },
            true,
            .fo(sdk),
            args,
        );
    }

    pub inline fn getField(
        self: *Scope,
        managed: api.sdk.ManagedObject,
        field_name: [:0]const u8,
        comptime T: type,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
    ) !T {
        return self.getFieldWithInterop(managed, field_name, T, defaultToZigInterop(T), .fo(sdk));
    }

    pub inline fn getFieldWithInterop(
        self: *Scope,
        managed: api.sdk.ManagedObject,
        field_name: [:0]const u8,
        comptime T: type,
        comptime interop: ToZigInterop(T),
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
    ) !T {
        const type_def = managed.getTypeDefinition(.fo(sdk)) orelse return error.NoTypeDefFound;
        return try self.getFieldFromTypeDef(managed.raw, type_def, field_name, T, interop, true, .fo(sdk));
    }

    pub inline fn getStaticField(
        self: *Scope,
        managed_type_name: [:0]const u8,
        field_name: [:0]const u8,
        comptime T: type,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .type_definition = .all,
            .functions = .get_tdb,
            .tdb = .find_type,
        }),
    ) !T {
        return self.getStaticFieldWithInterop(managed_type_name, field_name, T, defaultToZigInterop(T), .fo(sdk));
    }

    pub inline fn getStaticFieldWithInterop(
        self: *Scope,
        managed_type_name: [:0]const u8,
        field_name: [:0]const u8,
        comptime T: type,
        comptime interop: ToZigInterop(T),
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .type_definition = .all,
            .functions = .get_tdb,
            .tdb = .find_type,
        }),
    ) !T {
        const tdb = api.sdk.getTdb(.fo(sdk)) orelse return error.TdbNull;
        const type_def = tdb.findType(.fo(sdk), managed_type_name) orelse return error.NoTypeDefFound;
        return try self.getFieldFromTypeDef(null, type_def, field_name, T, interop, false, .fo(sdk));
    }

    pub inline fn setField(
        self: *Scope,
        managed: api.sdk.ManagedObject,
        field_name: [:0]const u8,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
        value: anytype,
    ) !void {
        return self.setFieldWithInterop(managed, field_name, defaultFromZigInterop, .fo(sdk), value);
    }

    pub inline fn setFieldWithInterop(
        self: *Scope,
        managed: api.sdk.ManagedObject,
        field_name: [:0]const u8,
        comptime interop: FromZigInterop,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .managed_object = sdk_managed_specs.managed_object,
            .type_definition = .all,
        }),
        value: anytype,
    ) !void {
        const type_def = managed.getTypeDefinition(.fo(sdk)) orelse return error.NoTypeDefFound;
        return try self.setFieldFromTypeDef(managed.raw, type_def, field_name, interop, true, false, .fo(sdk), value);
    }

    pub inline fn setStaticField(
        self: *Scope,
        managed_type_name: [:0]const u8,
        field_name: [:0]const u8,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .type_definition = .all,
            .functions = .get_tdb,
            .tdb = .find_type,
        }),
        value: anytype,
    ) !void {
        return self.setStaticFieldWithInterop(managed_type_name, field_name, defaultFromZigInterop, .fo(sdk), value);
    }

    pub inline fn setStaticFieldWithInterop(
        self: *Scope,
        managed_type_name: [:0]const u8,
        field_name: [:0]const u8,
        comptime interop: FromZigInterop,
        sdk: api.VerifiedSdk(.{
            .field = sdk_managed_specs.field,
            .type_definition = .all,
            .functions = .get_tdb,
            .tdb = .find_type,
        }),
        value: anytype,
    ) !void {
        const tdb = api.sdk.getTdb(.fo(sdk)) orelse return error.TdbNull;
        const type_def = tdb.findType(.fo(sdk), managed_type_name) orelse return error.NoTypeDefFound;
        return try self.setFieldFromTypeDef(null, type_def, field_name, interop, false, true, .fo(sdk), value);
    }
};

/// Represents a resolved managed type with "static" cached metadata, which allows invoking methods
/// and accessing fields, but the method signatures and field names have to be comptime-known,
/// and has to provided to each respective function calls. The cached "metadata"s out-lives the scope.
///
/// Basically `ManagedObjectType` but without manually "creating" the type at comptime but
/// "creates" some sort of metdata cache map as you use it.
pub fn ResolvedType(comptime type_name: [:0]const u8) type {
    return struct {
        var cached_metadata: std.atomic.Value(?*TypeDefMetadata) = .init(null);

        type_def_metadata: *TypeDefMetadata,

        const ResolvedT = @This();

        pub fn init(cache: *ManagedTypeCache, tdb: api.sdk.Tdb, sdk: api.VerifiedSdk(.{ .tdb = .find_type })) !ResolvedT {
            return .{
                .type_def_metadata = try getTypeDefMetadata(cache, tdb, .fo(sdk)),
            };
        }

        pub inline fn scoped(self: ResolvedT, scope: *Scope) Scoped {
            return .{
                .scope = scope,
                .type_def_metadata = self.type_def_metadata,
            };
        }

        fn getObj(obj: anytype) ?*anyopaque {
            const ObjType = @TypeOf(obj);
            switch (ObjType) {
                api.sdk.ManagedObject => {
                    return obj.raw;
                },
                *api.sdk.ManagedObject => {
                    return obj.*.raw;
                },
                ValueType => {
                    return obj.valuePtr();
                },
                else => return null,
            }

            if (isManagedInterop(ObjType)) {
                return obj.managed.raw;
            }

            const obj_type_info = @typeInfo(ObjType);
            switch (obj_type_info) {
                .pointer => |p| {
                    if (p.child == ValueType) {
                        return obj.valuePtr();
                    }
                    return @ptrCast(@alignCast(obj));
                },
                .optional => |o| {
                    if (o) |val| {
                        return getObj(val);
                    } else {
                        return null;
                    }
                },
                .null => return null,
                .undefined => return null,
                else => {
                    @compileError("Only pointer types, optional pointer types, ManagedObject or interop structs with 'managed' field are supported as method call object.");
                },
            }
        }

        fn getObjDetectManaged(obj: anytype) struct { ?*anyopaque, bool } {
            const ObjType = @TypeOf(obj);
            const isManagedObj = struct {
                inline fn func(comptime T: type) bool {
                    return isManagedInterop(T) or
                        T == api.sdk.ManagedObject or
                        T == @TypeOf((api.sdk.ManagedObject{ .raw = null }).raw);
                }
            }.func;
            if (isManagedObj(ObjType)) {
                return .{ getObj(obj), true };
            }

            const obj_type_info = @typeInfo(ObjType);
            switch (obj_type_info) {
                .pointer => |p| {
                    return .{ getObj(obj), isManagedObj(p.child) };
                },
                .optional => |o| {
                    if (o) |val| {
                        return getObjDetectManaged(val);
                    } else {
                        return .{ null, isManagedObj(o.child) };
                    }
                },
                else => {
                    return .{ getObj(obj), false };
                },
            }
        }

        fn getTypeDefMetadata(cache: *ManagedTypeCache, tdb: api.sdk.Tdb, sdk: api.VerifiedSdk(.{ .tdb = .find_type })) !*TypeDefMetadata {
            return if (cached_metadata.load(.acquire)) |metadata| blk: {
                break :blk metadata;
            } else blk: {
                const type_def = tdb.findType(.fo(sdk), type_name) orelse return error.NoTypeDefFound;

                try cache.lock();
                defer cache.unlock();
                const new_metadata = try cache.getOrCacheTypeDefMetadata(type_def);
                cached_metadata.store(new_metadata, .release);
                break :blk new_metadata;
            };
        }

        // (Ab)using Zig's type memoization to cache metadata.
        fn Method(
            comptime sig: [:0]const u8,
            comptime param_interops: anytype,
            comptime RetType: type,
            comptime rInterop: ?ToZigInterop(RetType),
            comptime static: bool,
        ) type {
            return struct {
                const _sig = sig;
                const _param_interops = param_interops;
                const _RetType = RetType;
                const _rInterop = rInterop;
                const _static = static;

                var cached_metadata: std.atomic.Value(?*MethodMetadata) = .init(null);

                const MethodT = @This();

                fn getMetadata(
                    scope: *Scope,
                    type_def_metadata: *TypeDefMetadata,
                    sdk: api.VerifiedSdk(.{
                        .method = sdk_managed_specs.method,
                        .type_definition = .all,
                    }),
                ) !*MethodMetadata {
                    return if (MethodT.cached_metadata.load(.acquire)) |metadata| blk: {
                        break :blk metadata;
                    } else blk: {
                        try scope.cache.lock();
                        defer scope.cache.unlock();
                        const method_metadata = try scope.cache.getOrCacheMethodMetadataTo(type_def_metadata, MethodT._sig, .fo(sdk));

                        // We're not creating any new metadata here just storing the "reference" to already existing one
                        // so no need for cache arena.
                        MethodT.cached_metadata.store(method_metadata, .release);
                        break :blk method_metadata;
                    };
                }
            };
        }

        fn Field(
            comptime field_name: [:0]const u8,
            comptime static: bool,
        ) type {
            return struct {
                const _field_name = field_name;
                const _static = static;

                field_metadata: *FieldMetadata,
                is_passed_type_valtype: bool,

                const FieldT = @This();

                var cached_metadata: std.atomic.Value(?*FieldT) = .init(null);

                fn getMetadata(
                    scope: *Scope,
                    type_def_metadata: *TypeDefMetadata,
                    sdk: api.VerifiedSdk(.{
                        .field = sdk_managed_specs.field,
                        .type_definition = .all,
                    }),
                ) !struct { *FieldMetadata, bool } {
                    return if (FieldT.cached_metadata.load(.acquire)) |metadata| blk: {
                        break :blk .{ metadata.field_metadata, metadata.is_passed_type_valtype };
                    } else blk: {
                        try scope.cache.lock();
                        defer scope.cache.unlock();
                        const field_metadata = try scope.cache.getOrCacheFieldMetadataTo(type_def_metadata, FieldT._field_name, .fo(sdk));

                        const is_passed_type_valtype = type_def_metadata.def.getVmObjType(.fo(sdk)) == .valtype;

                        // We use the cache arena, we want this to live as long as the cache itself.
                        const static_storage = try scope.cache.cache_arena.allocator().create(FieldT);
                        static_storage.* = .{
                            .field_metadata = field_metadata,
                            .is_passed_type_valtype = is_passed_type_valtype,
                        };
                        FieldT.cached_metadata.store(static_storage, .release);
                        break :blk .{ field_metadata, is_passed_type_valtype };
                    };
                }
            };
        }

        const Scoped = struct {
            scope: *Scope,
            type_def_metadata: *TypeDefMetadata,

            const Self = @This();

            fn callMethodWithInteropsImpl(
                self: Self,
                obj: anytype,
                comptime sig: [:0]const u8,
                comptime param_interops: anytype,
                comptime RetType: type,
                comptime rInterop: ?ToZigInterop(RetType),
                comptime static: bool,
                sdk: api.VerifiedSdk(.{
                    .method = sdk_managed_specs.method,
                    .type_definition = .all,
                }),
                args: anytype,
            ) !RetType {
                const Static = Method(sig, param_interops, RetType, rInterop, static);
                const method_metadata = try Static.getMetadata(self.scope, self.type_def_metadata, .fo(sdk));

                const retInterop = comptime Static._rInterop orelse defaultToZigInterop(Static._RetType);
                return self.scope.invokeMethod(
                    getObj(obj),
                    method_metadata,
                    Static._param_interops,
                    .{ .type = Static._RetType, .interop = retInterop },
                    static,
                    .fo(sdk),
                    args,
                );
            }

            /// Calls instance method with the given method signature on the provided object.
            /// The method metadata is cached in a static struct to avoid redundant string allocations and comparisons on every call,
            /// so it's much faster when calling the same method multiple times.
            pub inline fn call(
                self: Self,
                obj: anytype,
                comptime sig: [:0]const u8,
                comptime RetType: type,
                sdk: api.VerifiedSdk(.{
                    .method = sdk_managed_specs.method,
                    .type_definition = .all,
                    .tdb = .find_type,
                }),
                args: anytype,
            ) !RetType {
                return self.callWithInterops(obj, sig, .{}, RetType, null, .fo(sdk), args);
            }

            /// Calls instance method with the given method signature on the provided object.
            /// Same as `Scope.callMethodWithInterops` but accepts comptime type name and method signature
            /// Stores them in a static struct to avoid redundant string allocations and comparisons on every call,
            /// so it's much faster when calling the same method multiple times.
            pub fn callWithInterops(
                self: Self,
                obj: anytype,
                comptime sig: [:0]const u8,
                comptime param_interops: anytype,
                comptime RetType: type,
                comptime rInterop: ?ToZigInterop(RetType),
                sdk: api.VerifiedSdk(.{
                    .method = sdk_managed_specs.method,
                    .type_definition = .all,
                    .tdb = .find_type,
                }),
                args: anytype,
            ) !RetType {
                return self.callMethodWithInteropsImpl(obj, sig, param_interops, RetType, rInterop, false, .fo(sdk), args);
            }

            /// Same as `callMethod` but for static methods, see its documentation for details.
            pub inline fn callStaticMethod(
                self: Self,
                comptime sig: [:0]const u8,
                comptime RetType: type,
                sdk: api.VerifiedSdk(.{
                    .method = sdk_managed_specs.method,
                    .type_definition = .all,
                    .tdb = .find_type,
                }),
                args: anytype,
            ) !RetType {
                return self.callStaticMethodWithInterops(sig, .{}, RetType, null, .fo(sdk), args);
            }

            /// Same as `callMethodWithInterops` but for static methods, see its documentation for details.
            pub fn callStaticMethodWithInterops(
                self: Self,
                comptime sig: [:0]const u8,
                comptime param_interops: anytype,
                comptime RetType: type,
                comptime rInterop: ?ToZigInterop(RetType),
                sdk: api.VerifiedSdk(.{
                    .method = sdk_managed_specs.method,
                    .type_definition = .all,
                    .tdb = .find_type,
                }),
                args: anytype,
            ) !RetType {
                return self.callMethodWithInteropsImpl(null, sig, param_interops, RetType, rInterop, true, .fo(sdk), args);
            }

            fn getFieldWithInteropImpl(
                self: Self,
                obj: anytype,
                comptime field: @EnumLiteral(),
                comptime T: type,
                comptime interop: ToZigInterop(T),
                comptime static: bool,
                sdk: api.VerifiedSdk(.{
                    .field = sdk_managed_specs.field,
                    .type_definition = .all,
                    .tdb = .find_type,
                }),
            ) !T {
                const Static = Field(@tagName(field), static);
                const field_metadata = (try Static.getMetadata(self.scope, self.type_def_metadata, .fo(sdk))).@"0";

                return self.scope.readField(
                    getObj(obj),
                    field_metadata,
                    T,
                    interop,
                    static,
                    .fo(sdk),
                );
            }

            pub inline fn get(
                self: Self,
                obj: anytype,
                comptime field: @EnumLiteral(),
                comptime T: type,
                sdk: api.VerifiedSdk(.{
                    .field = sdk_managed_specs.field,
                    .type_definition = .all,
                    .tdb = .find_type,
                }),
            ) !T {
                return self.getWithInterop(obj, field, T, defaultToZigInterop(T), .fo(sdk));
            }

            pub fn getWithInterop(
                self: Self,
                obj: anytype,
                comptime field: @EnumLiteral(),
                comptime T: type,
                comptime interop: ToZigInterop(T),
                sdk: api.VerifiedSdk(.{
                    .field = sdk_managed_specs.field,
                    .type_definition = .all,
                    .tdb = .find_type,
                }),
            ) !T {
                return self.getFieldWithInteropImpl(obj, field, T, interop, false, .fo(sdk));
            }

            pub inline fn getStatic(
                self: Self,
                comptime field: @EnumLiteral(),
                comptime T: type,
                sdk: api.VerifiedSdk(.{
                    .field = sdk_managed_specs.field,
                    .type_definition = .all,
                    .tdb = .find_type,
                }),
            ) !T {
                return self.getStaticWithInterop(field, T, defaultToZigInterop(T), .fo(sdk));
            }

            pub inline fn getStaticWithInterop(
                self: Self,
                comptime field: @EnumLiteral(),
                comptime T: type,
                comptime interop: ToZigInterop(T),
                sdk: api.VerifiedSdk(.{
                    .field = sdk_managed_specs.field,
                    .type_definition = .all,
                    .tdb = .find_type,
                }),
            ) !T {
                return self.getFieldWithInteropImpl(null, field, T, interop, true, .fo(sdk));
            }

            fn setFieldWithInteropImpl(
                self: Self,
                obj: anytype,
                comptime field: @EnumLiteral(),
                comptime interop: FromZigInterop,
                comptime static: bool,
                sdk: api.VerifiedSdk(.{
                    .field = sdk_managed_specs.field,
                    .type_definition = .all,
                    .tdb = .find_type,
                }),
                value: anytype,
            ) !void {
                const Static = Field(@tagName(field), static);
                const field_metadata, const is_passed_type_valtype = try Static.getMetadata(self.scope, self.type_def_metadata, .fo(sdk));

                const obj_val, const passed_managed_obj = getObjDetectManaged(obj);
                return self.scope.writeField(
                    obj_val,
                    field_metadata,
                    interop,
                    is_passed_type_valtype and !passed_managed_obj,
                    static,
                    .fo(sdk),
                    value,
                );
            }

            pub inline fn set(
                self: Self,
                obj: anytype,
                comptime field: @EnumLiteral(),
                sdk: api.VerifiedSdk(.{
                    .field = sdk_managed_specs.field,
                    .type_definition = .all,
                    .tdb = .find_type,
                }),
                value: anytype,
            ) !void {
                return self.setWithInterop(obj, field, defaultFromZigInterop, .fo(sdk), value);
            }

            pub inline fn setWithInterop(
                self: Self,
                obj: anytype,
                comptime field: @EnumLiteral(),
                comptime interop: FromZigInterop,
                sdk: api.VerifiedSdk(.{
                    .field = sdk_managed_specs.field,
                    .type_definition = .all,
                    .tdb = .find_type,
                }),
                value: anytype,
            ) !void {
                return self.setFieldWithInteropImpl(obj, field, interop, false, .fo(sdk), value);
            }

            pub inline fn setStatic(
                self: Self,
                comptime field: @EnumLiteral(),
                sdk: api.VerifiedSdk(.{
                    .field = sdk_managed_specs.field,
                    .type_definition = .all,
                    .tdb = .find_type,
                }),
                value: anytype,
            ) !void {
                return self.setStaticWithInterop(field, defaultFromZigInterop, .fo(sdk), value);
            }

            pub fn setStaticWithInterop(
                self: Self,
                comptime field: @EnumLiteral(),
                comptime interop: FromZigInterop,
                sdk: api.VerifiedSdk(.{
                    .field = sdk_managed_specs.field,
                    .type_definition = .all,
                    .functions = .{.get_tdb},
                    .tdb = .find_type,
                }),
                value: anytype,
            ) !void {
                return self.setFieldWithInteropImpl(null, field, interop, true, .fo(sdk), value);
            }
        };
    };
}

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

    pub fn init(arena: std.mem.Allocator, sdk: ManagedSdk, data: *?*anyopaque, type_def: api.sdk.TypeDefinition) !Self {
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

    pub inline fn valuePtr(self: Self) ?*anyopaque {
        return @ptrCast(@alignCast(&self.data[managed_object_runtime_size]));
    }

    pub inline fn call(
        self: Self,
        comptime sig: [:0]const u8,
        comptime param_interops: anytype,
        comptime ret: anytype,
        scope: *Scope,
        sdk: api.VerifiedSdk(.{
            .method = sdk_managed_specs.method,
            .managed_object = sdk_managed_specs.managed_object,
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
            .field = sdk_managed_specs.field,
            .managed_object = sdk_managed_specs.managed_object,
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
            .field = sdk_managed_specs.field,
            .managed_object = sdk_managed_specs.managed_object,
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
            false,
            .fo(sdk),
            value,
        );
    }
};

pub const SystemStringView = struct {
    data: [:0]const u16,
};

pub const FromZigInterop = fn (
    userdata: ?*anyopaque,
    scope: *Scope,
    to_type_def: api.sdk.TypeDefinition,
    arg: anytype,
    out: *?*anyopaque,
) anyerror!void;

pub fn ToZigInterop(comptime T: type) type {
    return fn (
        userdata: ?*anyopaque,
        scope: *Scope,
        from_type_def: api.sdk.TypeDefinition,
        data: *?*anyopaque,
    ) anyerror!T;
}

// TODO: Implement more cases:
// https://github.com/praydog/REFramework/blob/ea66d322fbe2ebb7e2efd8fd6aa6b06779da6f76/src/mods/bindings/Sdk.cpp#L1086
pub fn defaultFromZigInterop(
    userdata: ?*anyopaque,
    scope: *Scope,
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
            return defaultFromZigInterop(userdata, scope, to_type_def, arg.data, out);
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
            return defaultFromZigInterop(userdata, scope, to_type_def, enum_val, out);
        },
        .@"struct" => {
            @compileError("Cannot interop zig struct");
        },
        .optional => |o| {
            if (@typeInfo(o.child) != .@"struct" and @typeInfo(o.child) != .pointer) {
                @compileError("Option struct and pointer types are the only supported optional types. Found: '" ++ @typeName(ArgT) ++ "'");
            }

            if (arg) |v| {
                try defaultFromZigInterop(userdata, scope, to_type_def, v, out);
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
    len: u32,
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
pub fn defaultToZigInterop(RetType: type) fn (?*anyopaque, *Scope, api.sdk.TypeDefinition, *?*anyopaque) anyerror!RetType {
    return struct {
        fn func(
            userdata: ?*anyopaque,
            scope: *Scope,
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
                    return try ValueType.init(scope.arena.allocator(), sdk, data, from_type_def);
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
                return try RetType.init(scope.cache, sdk, obj);
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
                    return @enumFromInt(try defaultToZigInterop(EnumUnderlyingT)(userdata, scope, from_type_def, data));
                },
                .optional => |o| {
                    if (@typeInfo(o.child) != .@"struct" and @typeInfo(o.child) != .pointer) {
                        @compileError("Option struct and pointer types are the only supported optional types for return values. Found: '" ++ @typeName(RetType) ++ "'");
                    }
                    const ptr: ?*anyopaque = data.*;
                    if (ptr == null) return null;

                    return try defaultToZigInterop(o.child)(userdata, scope, from_type_def, data);
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

inline fn buildMethodSignatureParams(comptime method_name: [:0]const u8, comptime params: []const MethodParam) [:0]const u8 {
    return comptime blk: {
        for (params) |param| {
            if (param.type_name == null) {
                break :blk method_name;
            }
        }

        var sig: [:0]const u8 = method_name ++ "(";
        if (params.len > 0) {
            sig = std.fmt.comptimePrint("{s}{s}", .{ sig, params[0].type_name.? });
            for (1..params.len) |i| {
                sig = std.fmt.comptimePrint("{s}, {s}", .{ sig, params[i].type_name.? });
            }
        }
        sig = std.fmt.comptimePrint("{s})", .{sig});
        break :blk sig;
    };
}

fn buildMethodArgsFromData(
    Data: type,
    userdata: ?*anyopaque,
    scope: *Scope,
    method_metadata: *const MethodMetadata,
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

    return buildMethodArgsImpl(userdata, scope, method_metadata, args, param_interops);
}

fn buildMethodArgsImpl(
    userdata: ?*anyopaque,
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
                userdata,
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
    userdata: ?*anyopaque,
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

    return buildMethodArgsImpl(userdata, scope, method_metadata, args, param_interop_fns);
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
            scope: *Scope,
            from_type_def: api.sdk.TypeDefinition,
            field_raw_data: *?*anyopaque,
        ) anyerror!FieldType {
            // TODO: Add more safety fences?
            return defaultToZigInterop(FieldType)(userdata, scope, from_type_def, field_raw_data);
        }

        inline fn set(
            userdata: ?*anyopaque,
            scope: *Scope,
            to_type_def: api.sdk.TypeDefinition,
            value: FieldType,
            write_ptr: *?*anyopaque,
        ) anyerror!void {
            return defaultFromZigInterop(userdata, scope, to_type_def, value, write_ptr);
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
        var static_metadata: std.atomic.Value(?*ManagedObjectMetadata) = .init(null);

        metadata: *ManagedObjectMetadata,

        const ManagedObjectType = @This();

        pub const Instance = struct {
            managed: api.sdk.ManagedObject,
            runtime: Runtime,

            const Self = @This();
            pub const Runtime = ManagedObjectType;

            pub fn init(cache: *ManagedTypeCache, sdk: ManagedSdk, managed: api.sdk.ManagedObject) !Self {
                return checkedInit(cache, sdk, managed);
            }

            /// The provided sdk will be the userdata for each user-defined interop
            /// functions, we just won't have any compile-time checks for this.
            pub fn call(
                self: Self,
                comptime method: @EnumLiteral(),
                scope: *Scope,
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
                var built_args = try buildMethodArgsFromData(Data, @constCast(&sdk), scope, method_metadata, args);

                var invoke_res: api.InvokeRet = .{};
                try self.managed.invokeMethod(method_metadata.handle, .fo(sdk), &built_args, &invoke_res);

                if (invoke_res.exception_thrown) {
                    return error.ExceptionThrown;
                }

                const p: *?*anyopaque = @ptrCast(@alignCast(&invoke_res.bytes[0]));
                if (!@hasField(@TypeOf(method_data), "ret")) {
                    return try defaultToZigInterop(void)(
                        @constCast(&sdk),
                        scope,
                        method_metadata.ret_type_def,
                        p,
                    );
                } else {
                    // https://github.com/praydog/REFramework/blob/63dd83ead22bbab924b93bbd32e5be36d3a09a4d/src/mods/bindings/Sdk.cpp#L960
                    // TODO: Use type full name?
                    if (method_data.ret.type == f32 and !@hasField(@TypeOf(method_data.ret), "interop")) {
                        return @floatCast(try defaultToZigInterop(f64)(
                            @constCast(&sdk),
                            scope,
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
                            scope,
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
                scope: *Scope,
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
                    scope,
                    field_metadata.type_def,
                    data_read_ptr,
                );
            }

            // https://github.com/praydog/REFramework/blob/63dd83ead22bbab924b93bbd32e5be36d3a09a4d/src/mods/bindings/Sdk.cpp#L1232
            pub fn set(
                self: Self,
                comptime field: @EnumLiteral(),
                scope: *Scope,
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
                    scope,
                    field_metadata.type_def,
                    value,
                    data_write_ptr,
                );
            }

            pub inline fn callStatic(
                self: Self,
                comptime method: @EnumLiteral(),
                scope: *Scope,
                sdk: ManagedSdk,
                args: anytype,
            ) !getMethodData(methods, method).RetType() {
                return self.runtime.callStatic(method, scope, sdk, args);
            }

            pub inline fn getStatic(
                self: Self,
                comptime field: @EnumLiteral(),
                scope: *Scope,
                sdk: ManagedSdk,
            ) !FieldData(Instance, fields, field).Type {
                @setRuntimeSafety(false);
                return self.runtime.getStatic(field, scope, sdk);
            }

            pub inline fn setStatic(
                self: Self,
                comptime field: @EnumLiteral(),
                scope: *Scope,
                sdk: ManagedSdk,
                value: FieldData(Instance, fields, field).Type,
            ) !void {
                return self.runtime.setStatic(field, scope, sdk, value);
            }

            pub inline fn fullTypeName() [:0]const u8 {
                return full_type_name;
            }
        };

        pub fn get(cache: *ManagedTypeCache, sdk: ManagedSdk.Extend(.{
            .functions = .{ .extend = .get_tdb },
            .tdb = .find_type,
        })) !ManagedObjectType {
            return blk: {
                if (getStaticRuntime()) |runtime| {
                    break :blk runtime;
                } else {
                    const tdb = api.sdk.getTdb(.fo(sdk)) orelse return error.TdbNull;
                    const type_def = tdb.findType(.fo(sdk), full_type_name) orelse return error.NoTypeDefFound;
                    break :blk checkedRuntime(cache, .fo(sdk), type_def);
                }
            };
        }

        pub fn getWithTdb(cache: *ManagedTypeCache, sdk: ManagedSdk.Extend(.{ .tdb = .find_type }), tdb: api.sdk.Tdb) !ManagedObjectType {
            return blk: {
                if (getStaticRuntime()) |runtime| {
                    break :blk runtime;
                } else {
                    const type_def = tdb.findType(.fo(sdk), full_type_name) orelse return error.NoTypeDefFound;
                    break :blk checkedRuntime(cache, .fo(sdk), type_def);
                }
            };
        }

        pub fn instance(self: ManagedObjectType, managed: api.sdk.ManagedObject) Instance {
            return .{ .managed = managed, .runtime = self };
        }

        pub fn callStatic(
            self: ManagedObjectType,
            comptime method: @EnumLiteral(),
            scope: *Scope,
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
            var built_args = try buildMethodArgsFromData(Data, @constCast(&sdk), scope, method_metadata, args);

            var invoke_res: api.InvokeRet = .{};
            try method_metadata.handle.invoke(.fo(sdk), null, &built_args, &invoke_res);

            if (invoke_res.exception_thrown) {
                return error.ExceptionThrown;
            }

            const p: *?*anyopaque = @ptrCast(@alignCast(&invoke_res.bytes[0]));
            if (!@hasField(@TypeOf(method_data), "ret")) {
                return try defaultToZigInterop(void)(
                    @constCast(&sdk),
                    scope,
                    method_metadata.ret_type_def,
                    p,
                );
            } else {
                // https://github.com/praydog/REFramework/blob/63dd83ead22bbab924b93bbd32e5be36d3a09a4d/src/mods/bindings/Sdk.cpp#L960
                // TODO: Use type full name?
                if (method_data.ret.type == f32 and !@hasField(@TypeOf(method_data.ret), "interop")) {
                    return @floatCast(try defaultToZigInterop(f64)(
                        @constCast(&sdk),
                        scope,
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
                        scope,
                        method_metadata.ret_type_def,
                        p,
                    );
                }
            }
        }

        pub fn getStatic(
            self: ManagedObjectType,
            comptime field: @EnumLiteral(),
            scope: *Scope,
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
                scope,
                field_metadata.type_def,
                data_read_ptr,
            );
        }

        pub fn setStatic(
            self: ManagedObjectType,
            comptime field: @EnumLiteral(),
            scope: *Scope,
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
                scope,
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

        fn getStaticRuntime() ?ManagedObjectType {
            if (static_metadata.load(.acquire)) |metadata| {
                return .{ .metadata = metadata };
            }

            return null;
        }

        fn checkedInit(cache: *ManagedTypeCache, sdk: ManagedSdk, managed: api.sdk.ManagedObject) !Instance {
            const runtime = blk: {
                if (getStaticRuntime()) |runtime| {
                    break :blk runtime;
                } else {
                    const type_def = managed.getTypeDefinition(.fo(sdk)) orelse return error.NoTypeDefFound;
                    break :blk try checkedRuntime(cache, sdk, type_def);
                }
            };
            return .{
                .managed = managed,
                .runtime = runtime,
            };
        }

        fn checkedRuntime(cache: *ManagedTypeCache, sdk: ManagedSdk, type_def: api.sdk.TypeDefinition) !ManagedObjectType {
            const arena = cache.cache_arena.allocator();

            const method_names = comptime std.meta.fieldNames(@TypeOf(methods));
            var collected_methods = try std.ArrayList(*MethodMetadata).initCapacity(arena, method_names.len);
            defer collected_methods.deinit(arena);

            const field_names = comptime std.meta.fieldNames(@TypeOf(fields));
            var collected_fields = try std.ArrayList(*FieldMetadata).initCapacity(arena, field_names.len);
            defer collected_fields.deinit(arena);
            {
                try cache.lock();
                defer cache.unlock();

                // getting existing cached type_def metadata...
                const type_def_metdata = try cache.getOrCacheTypeDefMetadata(type_def);

                // Checking methods
                inline for (method_names) |default_method_name| {
                    // TODO: Check param Types, Return Type for interoperability.
                    const method_metadata = @field(methods, default_method_name);
                    const method_name = if (@hasField(@TypeOf(method_metadata), "name"))
                        method_metadata.name
                    else
                        default_method_name;
                    const method_sig = buildMethodSignature(method_name, method_metadata.params);

                    const method_cache_entry = try type_def_metdata.*.methods.getOrPut(method_sig);
                    if (method_cache_entry.found_existing) {
                        try collected_methods.append(
                            arena,
                            method_cache_entry.value_ptr.*,
                        );
                    } else {
                        // if we're removing on error, why not just not insert until we know it's valid?
                        // because it's a cold path, meaning these errors should happen rarely. otherwise,
                        // it's a user use case issue, they should be aware of what is available and what not.
                        errdefer type_def_metdata.*.methods.removeByPtr(method_cache_entry.key_ptr);

                        const method = type_def.findMethod(.fromOther(sdk), method_sig) orelse {
                            cache.appendError("'" ++ method_sig ++ "' was not found in '" ++ full_type_name ++ "'") catch {};
                            return error.MethodNotFound;
                        };
                        // Disclaimer: Deiniting one of them is enough to free all
                        // the resources associated with it, make sure to call deinit
                        // once during one of the map/list owner free.
                        const new_method_metadata = try arena.create(MethodMetadata);
                        new_method_metadata.* = try MethodMetadata.init(arena, .fo(sdk), method);

                        method_cache_entry.value_ptr.* = new_method_metadata;
                        try collected_methods.append(
                            arena,
                            new_method_metadata,
                        );
                    }
                }

                // Checking fields
                inline for (field_names) |field_name| {
                    // TODO: Check field Types for interoperability.
                    const field_cache_entry = try type_def_metdata.*.fields.getOrPut(field_name);

                    if (field_cache_entry.found_existing) {
                        try collected_fields.append(arena, field_cache_entry.value_ptr.*);
                    } else {
                        errdefer type_def_metdata.*.fields.removeByPtr(field_cache_entry.key_ptr);

                        const field_handle = type_def.findField(.fo(sdk), field_name) orelse {
                            cache.appendError("'" ++ field_name ++ "' was not found in '" ++ full_type_name ++ "'") catch {};
                            return error.FieldNotFound;
                        };
                        const field_type_def = field_handle.getType(.fo(sdk)) orelse {
                            cache.appendError("'" ++ full_type_name ++ "." ++ field_name ++ "' doesn't have any valid Type Definition") catch {};
                            return error.FieldInvalidType;
                        };

                        const new_field_metadata = try arena.create(FieldMetadata);
                        new_field_metadata.* = .{
                            .handle = field_handle,
                            .type_def = field_type_def,
                        };

                        field_cache_entry.value_ptr.* = new_field_metadata;
                        try collected_fields.append(arena, new_field_metadata);
                    }
                }
            }

            const metadata = try arena.create(ManagedObjectMetadata);
            metadata.* = .{
                .type_def = type_def,
                .methods = try collected_methods.toOwnedSlice(arena),
                .fields = try collected_fields.toOwnedSlice(arena),
            };
            static_metadata.store(metadata, .release);
            return .{ .metadata = metadata };
        }
    };

    return ManagedObjectType.Instance;
}

fn ManagedObjectNew(comptime Builder: type) type {
    return struct {
        var cached_metadata: std.atomic.Value(?*ManagedObjectMetadata) = .init(null);

        metadata: *ManagedObjectMetadata,

        pub const fullTypeName = Builder.fullTypeName;

        fn ComptimeFieldType(comptime field: @EnumLiteral()) type {
            return if (Builder.GetField(field).Type == void)
                Instance
            else
                Builder.GetField(field).Type;
        }

        const ManagedObjectType = @This();

        pub const Instance = struct {
            managed: api.sdk.ManagedObject,
            runtime: Runtime,

            const Self = @This();
            pub const Runtime = ManagedObjectType;

            pub fn init(cache: *ManagedTypeCache, sdk: ManagedSdk, managed: api.sdk.ManagedObject) !Self {
                return checkedInit(cache, sdk, managed);
            }

            /// The provided sdk will be the userdata for each user-defined interop
            /// functions, we just won't have any compile-time checks for this.
            pub inline fn call(
                self: Self,
                comptime method: @EnumLiteral(),
                scope: *Scope,
                sdk: ManagedSdk,
                args: anytype,
            ) !Builder.GetMethod(method).RetType {
                const Method = Builder.GetMethod(method);

                const method_metadata = self.runtime.metadata.methods[Method.Id];
                return scope.invokeMethod(
                    self.managed.raw,
                    method_metadata,
                    Method.ParamInteropsTuple,
                    .{ .type = Method.RetType, .interop = Method.retInterop },
                    false,
                    .fo(sdk),
                    args,
                );
            }

            // https://github.com/praydog/REFramework/blob/63dd83ead22bbab924b93bbd32e5be36d3a09a4d/src/mods/bindings/Sdk.cpp#L1246
            pub inline fn get(
                self: Self,
                comptime field: @EnumLiteral(),
                scope: *Scope,
                sdk: ManagedSdk,
            ) !ComptimeFieldType(field) {
                const Field = Builder.GetField(field);
                const field_metadata = self.runtime.metadata.fields[Field.Id];
                return scope.readField(
                    self.managed.raw,
                    field_metadata,
                    Field.Type,
                    Field.get,
                    false,
                    .fo(sdk),
                );
            }

            // https://github.com/praydog/REFramework/blob/63dd83ead22bbab924b93bbd32e5be36d3a09a4d/src/mods/bindings/Sdk.cpp#L1232
            pub inline fn set(
                self: Self,
                comptime field: @EnumLiteral(),
                scope: *Scope,
                sdk: ManagedSdk,
                value: ComptimeFieldType(field),
            ) !void {
                const Field = Builder.GetField(field);
                const field_metadata = self.runtime.metadata.fields[Field.Id];
                return scope.writeField(
                    self.managed.raw,
                    field_metadata,
                    Field.set,
                    false,
                    false,
                    .fo(sdk),
                    value,
                );
            }

            pub inline fn callStatic(
                self: Self,
                comptime method: @EnumLiteral(),
                scope: *Scope,
                sdk: ManagedSdk,
                args: anytype,
            ) !Builder.GetMethod(method).RetType {
                return self.runtime.callStatic(method, sdk, scope, args);
            }

            pub inline fn getStatic(
                self: Self,
                comptime field: @EnumLiteral(),
                scope: *Scope,
                sdk: ManagedSdk,
            ) !ComptimeFieldType(field) {
                @setRuntimeSafety(false);
                return self.runtime.getStatic(field, sdk, scope);
            }

            pub inline fn setStatic(
                self: Self,
                comptime field: @EnumLiteral(),
                scope: *Scope,
                sdk: ManagedSdk,
                value: ComptimeFieldType(field),
            ) !void {
                return self.runtime.setStatic(field, scope, sdk, value);
            }

            pub const fullTypeName = Builder.fullTypeName;
        };

        pub fn get(cache: *ManagedTypeCache, sdk: ManagedSdk.Extend(.{
            .functions = .{ .extend = .get_tdb },
            .tdb = .find_type,
        })) !ManagedObjectType {
            return blk: {
                if (getStaticRuntime()) |runtime| {
                    break :blk runtime;
                } else {
                    const tdb = api.sdk.getTdb(.fo(sdk)) orelse return error.TdbNull;
                    const type_def = tdb.findType(.fo(sdk), fullTypeName()) orelse return error.NoTypeDefFound;
                    break :blk checkedRuntime(cache, .fo(sdk), type_def);
                }
            };
        }

        pub fn getWithTdb(cache: *ManagedTypeCache, sdk: ManagedSdk.Extend(.{ .tdb = .find_type }), tdb: api.sdk.Tdb) !ManagedObjectType {
            return blk: {
                if (getStaticRuntime()) |runtime| {
                    break :blk runtime;
                } else {
                    const type_def = tdb.findType(.fo(sdk), fullTypeName()) orelse return error.NoTypeDefFound;
                    break :blk checkedRuntime(cache, .fo(sdk), type_def);
                }
            };
        }

        pub fn instance(self: ManagedObjectType, managed: api.sdk.ManagedObject) Instance {
            return .{ .managed = managed, .runtime = self };
        }

        pub inline fn callStatic(
            self: ManagedObjectType,
            comptime method: @EnumLiteral(),
            scope: *Scope,
            sdk: ManagedSdk,
            args: anytype,
        ) !Builder.GetMethod(method).RetType {
            const Method = Builder.GetMethod(method);
            const method_metadata = self.metadata.methods[Method.Id];
            return scope.invokeMethod(
                null,
                method_metadata,
                Method.ParamInteropsTuple,
                .{ .type = Method.RetType, .interop = Method.retInterop },
                true,
                .fo(sdk),
                args,
            );
        }

        pub fn getStatic(
            self: ManagedObjectType,
            comptime field: @EnumLiteral(),
            scope: *Scope,
            sdk: ManagedSdk,
        ) !ComptimeFieldType(field) {
            @setRuntimeSafety(false);
            const Field = Builder.GetField(field);

            const field_metadata = self.metadata.fields[Field.Id];
            return scope.readField(null, field_metadata, ComptimeFieldType(field), Field.get, false, .fo(sdk));
        }

        pub inline fn setStatic(
            self: ManagedObjectType,
            comptime field: @EnumLiteral(),
            scope: *Scope,
            sdk: ManagedSdk,
            value: ComptimeFieldType(field),
        ) !void {
            @setRuntimeSafety(false);
            const Field = Builder.GetField(field);

            const field_metadata = self.metadata.fields[Field.Id];
            return scope.writeField(null, field_metadata, Field.set, false, true, .fo(sdk), value);
        }

        pub inline fn getMethod(self: ManagedObjectType, comptime method: @EnumLiteral()) api.sdk.Method {
            const Method = Builder.GetMethod(method);
            return self.metadata.methods[Method.Id].handle;
        }

        fn getStaticRuntime() ?ManagedObjectType {
            if (cached_metadata.load(.acquire)) |metadata| {
                return .{ .metadata = metadata };
            }

            return null;
        }

        fn checkedInit(cache: *ManagedTypeCache, sdk: ManagedSdk, managed: api.sdk.ManagedObject) !Instance {
            const runtime = blk: {
                if (getStaticRuntime()) |runtime| {
                    break :blk runtime;
                } else {
                    const type_def = managed.getTypeDefinition(.fo(sdk)) orelse return error.NoTypeDefFound;
                    break :blk try checkedRuntime(cache, sdk, type_def);
                }
            };
            return .{
                .managed = managed,
                .runtime = runtime,
            };
        }

        fn checkedRuntime(cache: *ManagedTypeCache, sdk: ManagedSdk, type_def: api.sdk.TypeDefinition) !ManagedObjectType {
            const arena = cache.cache_arena.allocator();

            var collected_methods = try std.ArrayList(*MethodMetadata).initCapacity(arena, Builder.MethodList.MethodsLen);
            defer collected_methods.deinit(arena);

            var collected_fields = try std.ArrayList(*FieldMetadata).initCapacity(arena, Builder.FieldList.FieldsLen);
            defer collected_fields.deinit(arena);
            {
                try cache.lock();
                defer cache.unlock();

                // getting existing cached type_def metadata...
                const type_def_metdata = try cache.getOrCacheTypeDefMetadata(type_def);

                // Checking methods
                inline for (Builder.MethodList.Methods) |method_comptime_data| {
                    // TODO: Check param Types, Return Type for interoperability?
                    const method_cache_entry = try type_def_metdata.*.methods.getOrPut(method_comptime_data.Signature);
                    if (method_cache_entry.found_existing) {
                        try collected_methods.append(arena, method_cache_entry.value_ptr.*);
                    } else {
                        // if we're removing on error, why not just not insert until we know it's valid?
                        // because it's a cold path, meaning these errors should happen rarely. otherwise,
                        // it's a user use case issue, they should be aware of what is available and what not.
                        errdefer type_def_metdata.*.methods.removeByPtr(method_cache_entry.key_ptr);

                        const method = type_def.findMethod(.fromOther(sdk), method_comptime_data.Signature) orelse {
                            cache.appendError("'" ++ method_comptime_data.Signature ++ "' was not found in '" ++ fullTypeName() ++ "'") catch {};
                            return error.MethodNotFound;
                        };
                        // Disclaimer: Deiniting one of them is enough to free all
                        // the resources associated with it, make sure to call deinit
                        // once during one of the map/list owner free.
                        const new_method_metadata = try arena.create(MethodMetadata);
                        new_method_metadata.* = try MethodMetadata.init(arena, .fo(sdk), method);

                        method_cache_entry.value_ptr.* = new_method_metadata;
                        try collected_methods.append(arena, new_method_metadata);
                    }
                }

                // Checking fields
                inline for (Builder.FieldList.Fields) |field_comptime_data| {
                    // TODO: Check field Types for interoperability.
                    const field_name = @tagName(field_comptime_data.Name);
                    const field_cache_entry = try type_def_metdata.*.fields.getOrPut(field_name);
                    if (field_cache_entry.found_existing) {
                        try collected_fields.append(arena, field_cache_entry.value_ptr.*);
                    } else {
                        errdefer type_def_metdata.*.fields.removeByPtr(field_cache_entry.key_ptr);

                        const field_handle = type_def.findField(.fo(sdk), field_name) orelse {
                            cache.appendError("'" ++ field_name ++ "' was not found in '" ++ fullTypeName() ++ "'") catch {};
                            return error.FieldNotFound;
                        };
                        const field_type_def = field_handle.getType(.fo(sdk)) orelse {
                            cache.appendError("'" ++ fullTypeName() ++ "." ++ field_name ++ "' doesn't have any valid Type Definition") catch {};
                            return error.FieldInvalidType;
                        };
                        const new_field_metadata = try arena.create(FieldMetadata);
                        new_field_metadata.* = .{
                            .handle = field_handle,
                            .type_def = field_type_def,
                        };

                        field_cache_entry.value_ptr.* = new_field_metadata;
                        try collected_fields.append(arena, new_field_metadata);
                    }
                }
            }

            const metadata = try arena.create(ManagedObjectMetadata);
            metadata.* = .{
                .type_def = type_def,
                .methods = try collected_methods.toOwnedSlice(arena),
                .fields = try collected_fields.toOwnedSlice(arena),
            };
            cached_metadata.store(metadata, .release);
            return .{ .metadata = metadata };
        }
    };
}

pub fn ManagedObjectTypeBuilder(comptime full_type_name: [:0]const u8) type {
    return ManagedObjectTypeBuilderImpl(full_type_name, ManagedObjectTypeBuilderFields(0, .{}), ManagedObjectTypeBuilderMethods(0, .{}));
}

fn ManagedObjectTypeBuilderImpl(comptime full_type_name: [:0]const u8, comptime NewFieldList: type, comptime NewMethodList: type) type {
    return struct {
        pub const FieldList: type = NewFieldList;
        pub const MethodList: type = NewMethodList;

        const Builder = @This();

        fn GetField(comptime field: @EnumLiteral()) type {
            for (0..FieldList.FieldsLen) |i| {
                if (field == FieldList.Fields[i].Name) {
                    return FieldList.Fields[i];
                }
            }
            @compileError("No field decl was found with name: " ++ @tagName(field));
        }

        fn GetMethod(comptime method: @EnumLiteral()) type {
            for (0..MethodList.MethodsLen) |i| {
                if (method == MethodList.Methods[i].Tag) {
                    return MethodList.Methods[i];
                }
            }
            @compileError("No method decl was found with name: " ++ @tagName(method));
        }

        pub inline fn Build() type {
            return ManagedObjectNew(@This()).Instance;
        }

        pub fn Field(
            comptime field: @EnumLiteral(),
            comptime T: type,
            comptime get: ?ToZigInterop(T),
            comptime set: ?FromZigInterop,
        ) type {
            var fields: [FieldList.FieldsLen + 1]type = undefined;
            inline for (0..FieldList.FieldsLen) |i| {
                fields[i] = FieldList.Fields[i];
            }
            fields[FieldList.FieldsLen] = ManagedObjectTypeField(
                FieldList.FieldsLen,
                field,
                T,
                get orelse defaultToZigInterop(T),
                set orelse defaultFromZigInterop,
            );
            return ManagedObjectTypeBuilderImpl(full_type_name, ManagedObjectTypeBuilderFields(FieldList.FieldsLen + 1, fields), MethodList);
        }

        pub fn Method(
            comptime tag: @EnumLiteral(),
            comptime RetType: type,
            comptime rInterop: ?ToZigInterop(RetType),
        ) type {
            var retInterop: ?ToZigInterop(RetType) = rInterop;
            if (RetType == f32 and retInterop == null) {
                // https://github.com/praydog/REFramework/blob/63dd83ead22bbab924b93bbd32e5be36d3a09a4d/src/mods/bindings/Sdk.cpp#L960
                // TODO: Use type full name?
                retInterop = struct {
                    inline fn func(
                        userdata: ?*anyopaque,
                        scope: *Scope,
                        from_type_def: api.sdk.TypeDefinition,
                        data: *?*anyopaque,
                    ) anyerror!RetType {
                        return @floatCast(defaultToZigInterop(f64)(userdata, scope, from_type_def, data));
                    }
                }.func;
            }

            return ManagedObjectTypeMethodBuilder(@This(), MethodList.MethodsLen, null, tag, RetType, retInterop orelse defaultToZigInterop(RetType));
        }

        pub fn MethodWithName(
            comptime name: [:0]const u8,
            comptime tag: @EnumLiteral(),
            comptime RetType: type,
            comptime rInterop: ?ToZigInterop(RetType),
        ) type {
            var retInterop: ?ToZigInterop(RetType) = rInterop;
            if (RetType == f32 and retInterop == null) {
                // https://github.com/praydog/REFramework/blob/63dd83ead22bbab924b93bbd32e5be36d3a09a4d/src/mods/bindings/Sdk.cpp#L960
                // TODO: Use type full name?
                retInterop = struct {
                    inline fn func(
                        userdata: ?*anyopaque,
                        scope: *Scope,
                        from_type_def: api.sdk.TypeDefinition,
                        data: *?*anyopaque,
                    ) anyerror!RetType {
                        return @floatCast(defaultToZigInterop(f64)(userdata, scope, from_type_def, data));
                    }
                }.func;
            }

            return ManagedObjectTypeMethodBuilder(@This(), MethodList.MethodsLen, name, tag, RetType, retInterop orelse defaultToZigInterop(RetType));
        }

        pub inline fn fullTypeName() [:0]const u8 {
            return full_type_name;
        }
    };
}

fn ManagedObjectTypeField(
    comptime id: comptime_int,
    comptime field: @EnumLiteral(),
    comptime T: type,
    comptime getInterop: ToZigInterop(T),
    comptime setInterop: FromZigInterop,
) type {
    return struct {
        pub const Id = id;
        pub const Name: @EnumLiteral() = field;
        pub const Type: type = T;
        pub const get = getInterop;
        pub const set = setInterop;
    };
}

fn ManagedObjectTypeBuilderFields(comptime fields_len: comptime_int, comptime fields: [fields_len]type) type {
    return struct {
        pub const FieldsLen: comptime_int = fields_len;
        pub const Fields: [fields_len]type = fields;
    };
}

inline fn paramsInterops(
    comptime params_len: comptime_int,
    comptime params: [params_len]MethodParam,
) [params_len]FromZigInterop {
    var interops: [params_len]FromZigInterop = undefined;
    for (0..params_len) |i| {
        interops[i] = params[i].interop;
    }
    return interops;
}

inline fn ParamInteropsTupleType(
    comptime params_len: comptime_int,
) type {
    var interop_types: [params_len]type = @splat(FromZigInterop);
    return @Tuple(&interop_types);
}

inline fn paramInteropsTuple(
    comptime params_len: comptime_int,
    comptime params: [params_len]MethodParam,
) ParamInteropsTupleType(params_len) {
    var interops: ParamInteropsTupleType(params_len) = undefined;
    for (0..params_len) |i| {
        @field(interops, std.fmt.comptimePrint("{}", .{i})) = params[i].interop;
    }
    return interops;
}

fn ManagedObjectTypeMethod(
    comptime id: comptime_int,
    comptime name: ?[:0]const u8,
    comptime tag: @EnumLiteral(),
    comptime RType: type,
    comptime rInterop: ToZigInterop(RType),
    comptime params_len: comptime_int,
    comptime params: [params_len]MethodParam,
) type {
    return struct {
        pub const Id = id;
        pub const Name = name orelse @tagName(tag);
        pub const Tag: @EnumLiteral() = tag;
        pub const RetType: type = RType;
        pub const retInterop: ToZigInterop(RetType) = rInterop;
        pub const Params: [params_len]MethodParam = params;
        pub const ParamInterops = paramsInterops(params_len, params);
        pub const ParamInteropsTuple = paramInteropsTuple(params_len, params);
        pub const Signature = buildMethodSignatureParams(Name, &Params);
    };
}

fn ManagedObjectTypeBuilderMethods(comptime methods_len: comptime_int, comptime methods: [methods_len]type) type {
    return struct {
        pub const MethodsLen: comptime_int = methods_len;
        pub const Methods: [methods_len]type = methods;
    };
}

fn ManagedObjectTypeMethodBuilder(
    comptime TypeBuilder: type,
    comptime id: comptime_int,
    comptime name: ?[:0]const u8,
    comptime tag: @EnumLiteral(),
    comptime RType: type,
    comptime rInterop: ToZigInterop(RType),
) type {
    return ManagedObjectTypeMethodBuilderImpl(TypeBuilder, id, name, tag, RType, rInterop, 0, .{});
}

fn ManagedObjectTypeMethodBuilderImpl(
    comptime TypeBuilder: type,
    comptime id: comptime_int,
    comptime name: ?[:0]const u8,
    comptime tag: @EnumLiteral(),
    comptime RetType: type,
    comptime retInterop: ToZigInterop(RetType),
    comptime params_len: comptime_int,
    comptime params: [params_len]MethodParam,
) type {
    return struct {
        pub const ParamsLen = params_len;
        pub const Params: [params_len]MethodParam = params;

        /// Builds current "Method", adds it to the parent "Type Builder" and returns the built type.
        pub inline fn Build() type {
            return BuildMethod().Build();
        }

        /// Builds current "Method" and returns the type builder with the new method added, with
        /// the new field added.
        pub inline fn Field(
            comptime field: @EnumLiteral(),
            comptime T: type,
            comptime get: ?ToZigInterop(T),
            comptime set: ?FromZigInterop,
        ) type {
            return BuildMethod().Field(field, T, get, set);
        }

        /// Builds current "Method", adds it to the parent "Type Builder" and returns it.
        fn BuildMethod() type {
            var methods: [TypeBuilder.MethodList.MethodsLen + 1]type = undefined;
            inline for (0..TypeBuilder.MethodList.MethodsLen) |i| {
                methods[i] = TypeBuilder.MethodList.Methods[i];
                if (methods[i].Tag == tag) {
                    @compileError("Method with tag: " ++ @tagName(tag) ++ " was already defined, use MethodBuilderWithName, " ++
                        "provide a unique tag but provide the name as current tag's str literal.");
                }
            }
            methods[TypeBuilder.MethodList.MethodsLen] = ManagedObjectTypeMethod(
                id,
                name,
                tag,
                RetType,
                retInterop,
                ParamsLen,
                Params,
            );
            return ManagedObjectTypeBuilderImpl(
                TypeBuilder.fullTypeName(),
                TypeBuilder.FieldList,
                ManagedObjectTypeBuilderMethods(TypeBuilder.MethodList.MethodsLen + 1, methods),
            );
        }

        /// Adds a param to current "Method" and returns the "Method Builder" with the new param added.
        pub fn Param(type_name: ?[:0]const u8, T: type, interop: ?FromZigInterop) type {
            var new_params: [ParamsLen + 1]MethodParam = undefined;
            inline for (0..ParamsLen) |i| {
                new_params[i] = Params[i];
            }
            new_params[ParamsLen] = .{
                .type_name = type_name,
                .type = T,
                .interop = if (interop != null and interop != undefined)
                    interop
                else
                    defaultFromZigInterop,
            };
            return ManagedObjectTypeMethodBuilderImpl(TypeBuilder, id, name, tag, RetType, retInterop, ParamsLen + 1, new_params);
        }

        /// Builds current "Method" and returns a new "Method Builder"
        pub inline fn Method(
            comptime new_tag: @EnumLiteral(),
            comptime NewRetType: type,
            comptime newRetInterop: ?ToZigInterop(NewRetType),
        ) type {
            return BuildMethod().Method(new_tag, NewRetType, newRetInterop);
        }

        /// Builds current "Method" and returns a new "Method Builder"
        pub inline fn MethodWithName(
            comptime new_name: [:0]const u8,
            comptime new_tag: @EnumLiteral(),
            comptime NewRetType: type,
            comptime newRetInterop: ?ToZigInterop(NewRetType),
        ) type {
            return BuildMethod().MethodWithName(new_name, new_tag, NewRetType, newRetInterop);
        }
    };
}

test "builder" {
    const FooBuilder = ManagedObjectTypeBuilder("app.foo")
        .Field(.Test, i32, null, null)
        .Field(.Test2, f32, null, null)
        .Method(.TestMethod, void, null)
        .Method(.TestMethod2, void, null)
        .Param("System.Int32", i32, null)
        .Param("System.Int32", i32, null)
        .BuildMethod();

    try std.testing.expect(comptime FooBuilder.FieldList.FieldsLen == 2);
    try std.testing.expect(comptime FooBuilder.FieldList.Fields[0].Type == i32);
    try std.testing.expectEqualStrings("Test", @tagName(FooBuilder.FieldList.Fields[0].Name));
    try std.testing.expectEqualStrings("Test2", @tagName(FooBuilder.FieldList.Fields[1].Name));
    try std.testing.expectEqualStrings("TestMethod", FooBuilder.MethodList.Methods[0].Name);
    try std.testing.expect(comptime FooBuilder.MethodList.Methods[0].RetType == void);
    try std.testing.expectEqualStrings("TestMethod2", FooBuilder.MethodList.Methods[1].Name);
    try std.testing.expectEqualStrings("TestMethod2(System.Int32, System.Int32)", FooBuilder.MethodList.Methods[1].Signature);
    try std.testing.expect(comptime FooBuilder.MethodList.Methods[1].Params[0].type == i32);
    try std.testing.expect(comptime FooBuilder.MethodList.Methods[1].Params[1].type == i32);

    const Foo = FooBuilder.Build();
    try std.testing.expectEqual(std.hash_map.hashString("app.foo"), std.hash_map.hashString(Foo.Runtime.fullTypeName()));

    const FooT = struct {
        fn func(comptime name: [:0]const u8) type {
            return struct {
                pub const Name = name;
                pub fn GetNameStruct() type {
                    return struct {
                        pub const type_name = name;
                        pub const Type = void;
                    };
                }
            };
        }
    }.func;

    const Foo1 = FooT("Bar").GetNameStruct();
    const Foo2 = FooT("Bar").GetNameStruct();

    try std.testing.expect(comptime Foo1 == Foo2);
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
        try std.testing.expectEqual(69, res);
    }

    {
        @setRuntimeSafety(false);
        var arg: u32 = undefined;
        try defaultFromZigInterop(&dummy_sdk, &scope, dummy_typedef, 420, @ptrCast(@alignCast(&arg)));
        try std.testing.expectEqual(420, arg);
    }
}
