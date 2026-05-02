/// Should be used for scoped access to cached metadata and interop functions.
/// Not thread safe, should be created and used within the same thread, but multiple
/// scopes can exist at the same time.
const std = @import("std");
const type_utils = @import("../type_utils.zig");
const api = @import("../api.zig");

const m = @import("metadata.zig");
const MethodMetadata = m.MethodMetadata;
const FieldMetadata = m.FieldMetadata;

const isSafeMode = @import("misc.zig").isSafeMode;

const ManagedTypeCache = @import("managed_type_cache.zig").ManagedTypeCache;

const in = @import("../interop.zig");
const ValueType = in.ValueType;
const ToZigInterop = in.ToZigInterop;
const FromZigInterop = in.FromZigInterop;
const defaultToZigInterop = in.defaultToZigInterop;
const defaultFromZigInterop = in.defaultFromZigInterop;

cache: *ManagedTypeCache,
arena: std.heap.ArenaAllocator,

const Scope = @This();

pub const method_specs = api.specs.merge(.{ .invoke, .is_static }, MethodMetadata.method_specs);
pub const field_specs = api.specs.merge(.{ .get_data_raw, .is_static }, FieldMetadata.field_specs);
pub const managed_object_specs = .get_type_definition;

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
        .method = method_specs,
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

    var built_args = try buildMethodArgs(&sdk, self, method_metadata, args, param_interops);

    const managed: api.sdk.ManagedObject = .{ .raw = @ptrCast(@alignCast(obj)) };
    var invoke_res: api.InvokeRet = .{};
    try managed.invokeMethod(method_metadata.handle, .fo(sdk), &built_args, &invoke_res);

    const p: *?*anyopaque = @ptrCast(@alignCast(&invoke_res.bytes[0]));
    // https://github.com/praydog/REFramework/blob/63dd83ead22bbab924b93bbd32e5be36d3a09a4d/src/mods/bindings/Sdk.cpp#L960
    // TODO: Use type full name?
    if (ret.type == f32 and !@hasField(@TypeOf(ret), "interop")) {
        return @floatCast(try defaultToZigInterop(f64)(
            &sdk,
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
            &sdk,
            self,
            method_metadata.ret_type_def,
            p,
        );
    }
}

fn fieldPtr(
    self: *Scope,
    obj: *anyopaque,
    field_metadata: *FieldMetadata,
    sdk: api.VerifiedSdk(.{ .field = .get_data_raw }),
    is_obj_valtype: bool,
) !*?*anyopaque {
    @setRuntimeSafety(false);

    if (field_metadata.offset == m.invalid_offset) {
        @branchHint(.cold);
        try self.cache.lock();
        defer self.cache.unlock();

        const data_read_ptr: *?*anyopaque = @ptrCast(@alignCast(field_metadata.handle.getDataRaw(
            .fo(sdk),
            obj,
            is_obj_valtype,
        )));

        field_metadata.offset = @intFromPtr(data_read_ptr) - @intFromPtr(obj);
        return data_read_ptr;
    } else {
        return @ptrFromInt(@intFromPtr(obj) + field_metadata.offset);
    }
}

pub inline fn readField(
    self: *Scope,
    obj: *anyopaque,
    field_metadata: *FieldMetadata,
    comptime T: type,
    comptime interop: ?ToZigInterop(T),
    is_obj_valtype: bool,
    sdk: api.VerifiedSdk(.{
        .field = field_specs,
        .type_definition = .all,
    }),
) !T {
    const data_read_ptr: *?*anyopaque = try self.fieldPtr(obj, field_metadata, .fo(sdk), is_obj_valtype);
    const getInterop = interop orelse defaultToZigInterop(T);
    return getInterop(&sdk, self, field_metadata.type_def, data_read_ptr);
}

pub fn readStaticField(
    self: *Scope,
    field_metadata: *FieldMetadata,
    comptime T: type,
    comptime interop: ?ToZigInterop(T),
    sdk: api.VerifiedSdk(.{
        .field = field_specs,
        .type_definition = .all,
    }),
) !T {
    @setRuntimeSafety(false);

    const field_handle = field_metadata.handle;

    const data_read_ptr: *?*anyopaque = @ptrCast(@alignCast(field_handle.getDataRaw(
        .fo(sdk),
        null,
        false,
    )));

    const getInterop = interop orelse defaultToZigInterop(T);
    return getInterop(&sdk, self, field_metadata.type_def, data_read_ptr);
}

pub inline fn writeField(
    self: *Scope,
    obj: *anyopaque,
    field_metadata: *FieldMetadata,
    comptime interop: ?FromZigInterop,
    is_obj_valtype: bool,
    sdk: api.VerifiedSdk(.{
        .field = field_specs,
        .type_definition = .all,
    }),
    value: anytype,
) !void {
    const data_write_ptr: *?*anyopaque = try self.fieldPtr(obj, field_metadata, .fo(sdk), is_obj_valtype);
    const setInterop = interop orelse defaultFromZigInterop;
    return setInterop(&sdk, self, field_metadata.type_def, value, data_write_ptr);
}

pub fn writeStaticField(
    self: *Scope,
    field_metadata: *FieldMetadata,
    comptime interop: ?FromZigInterop,
    sdk: api.VerifiedSdk(.{
        .field = field_specs,
        .type_definition = .all,
    }),
    value: anytype,
) !void {
    @setRuntimeSafety(false);
    const is_valtype = field_metadata.type_def.getVmObjType(.fo(sdk)) == .valtype;
    const field_handle = field_metadata.handle;
    if (!field_handle.isStatic(.fo(sdk)) and !is_valtype) {
        return error.RequiresInstance;
    }

    const data_write_ptr: *?*anyopaque = @ptrCast(@alignCast(field_handle.getDataRaw(
        .fo(sdk),
        null,
        false,
    )));

    const setInterop = interop orelse defaultFromZigInterop;
    return setInterop(&sdk, self, field_metadata.type_def, value, data_write_ptr);
}

pub inline fn getFieldFromTypeDef(
    self: *Scope,
    obj: *anyopaque,
    type_def: api.sdk.TypeDefinition,
    field_name: [:0]const u8,
    comptime T: type,
    comptime interop: ?ToZigInterop(T),
    comptime passed_managed_obj: bool,
    sdk: api.VerifiedSdk(.{
        .field = field_specs,
        .type_definition = .all,
    }),
) !T {
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

pub inline fn getStaticFieldFromTypeDef(
    self: *Scope,
    type_def: api.sdk.TypeDefinition,
    field_name: [:0]const u8,
    comptime T: type,
    comptime interop: ?ToZigInterop(T),
    sdk: api.VerifiedSdk(.{
        .field = field_specs,
        .type_definition = .all,
    }),
) !T {
    const field_metadata = try self.cache.getOrCacheFieldMetadata(.fo(sdk), type_def, field_name);
    return self.readStaticField(
        field_metadata,
        T,
        interop,
        .fo(sdk),
    );
}

pub inline fn setFieldFromTypeDef(
    self: *Scope,
    obj: *anyopaque,
    type_def: api.sdk.TypeDefinition,
    field_name: [:0]const u8,
    comptime interop: ?FromZigInterop,
    comptime passed_managed_obj: bool,
    sdk: api.VerifiedSdk(.{
        .field = field_specs,
        .type_definition = .all,
    }),
    value: anytype,
) !void {
    const field_metadata = try self.cache.getOrCacheFieldMetadata(.fo(sdk), type_def, field_name);
    const is_passed_type_valtype = type_def.getVmObjType(.fo(sdk)) == .valtype;
    return self.writeField(
        obj,
        field_metadata,
        interop,
        is_passed_type_valtype and !passed_managed_obj,
        .fo(sdk),
        value,
    );
}

pub inline fn setStaticFieldFromTypeDef(
    self: *Scope,
    type_def: api.sdk.TypeDefinition,
    field_name: [:0]const u8,
    comptime interop: ?FromZigInterop,
    sdk: api.VerifiedSdk(.{
        .field = field_specs,
        .type_definition = .all,
    }),
    value: anytype,
) !void {
    const field_metadata = try self.cache.getOrCacheFieldMetadata(.fo(sdk), type_def, field_name);
    return self.writeStaticField(
        field_metadata,
        interop,
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
        .method = method_specs,
        .managed_object = managed_object_specs,
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
        .method = method_specs,
        .managed_object = managed_object_specs,
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
        .method = method_specs,
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
        .method = method_specs,
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
        .field = field_specs,
        .managed_object = managed_object_specs,
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
        .field = field_specs,
        .managed_object = managed_object_specs,
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
        .field = field_specs,
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
        .field = field_specs,
        .type_definition = .all,
        .functions = .get_tdb,
        .tdb = .find_type,
    }),
) !T {
    const tdb = api.sdk.getTdb(.fo(sdk)) orelse return error.TdbNull;
    const type_def = tdb.findType(.fo(sdk), managed_type_name) orelse return error.NoTypeDefFound;
    return try self.getStaticFieldFromTypeDef(type_def, field_name, T, interop, .fo(sdk));
}

pub inline fn setField(
    self: *Scope,
    managed: api.sdk.ManagedObject,
    field_name: [:0]const u8,
    sdk: api.VerifiedSdk(.{
        .field = field_specs,
        .managed_object = managed_object_specs,
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
        .field = field_specs,
        .managed_object = managed_object_specs,
        .type_definition = .all,
    }),
    value: anytype,
) !void {
    const type_def = managed.getTypeDefinition(.fo(sdk)) orelse return error.NoTypeDefFound;
    return try self.setFieldFromTypeDef(managed.raw, type_def, field_name, interop, true, .fo(sdk), value);
}

pub inline fn setStaticField(
    self: *Scope,
    managed_type_name: [:0]const u8,
    field_name: [:0]const u8,
    sdk: api.VerifiedSdk(.{
        .field = field_specs,
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
        .field = field_specs,
        .type_definition = .all,
        .functions = .get_tdb,
        .tdb = .find_type,
    }),
    value: anytype,
) !void {
    const tdb = api.sdk.getTdb(.fo(sdk)) orelse return error.TdbNull;
    const type_def = tdb.findType(.fo(sdk), managed_type_name) orelse return error.NoTypeDefFound;
    return try self.setStaticFieldFromTypeDef(type_def, field_name, interop, .fo(sdk), value);
}

pub const buildMethodArgs = in.buildMethodArgs;
