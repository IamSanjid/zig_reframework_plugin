const std = @import("std");
const api = @import("../api.zig");

const m = @import("metadata.zig");
const TypeDefMetadata = m.TypeDefMetadata;
const MethodMetadata = m.MethodMetadata;
const FieldMetadata = m.FieldMetadata;

const managed_type_cache = @import("managed_type_cache.zig");
const ManagedTypeCache = managed_type_cache.ManagedTypeCache;
const Scope = @import("Scope.zig");

const in = @import("../interop.zig");
const ValueType = in.ValueType;
const ToZigInterop = in.ToZigInterop;
const FromZigInterop = in.FromZigInterop;
const defaultToZigInterop = in.defaultToZigInterop;
const defaultFromZigInterop = in.defaultFromZigInterop;

const isManagedInterop = @import("type_builder.zig").isManagedInterop;

pub const tdb_specs = .find_type;
pub const method_specs = Scope.method_specs;
pub const field_specs = Scope.field_specs;

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

        pub fn init(cache: *ManagedTypeCache, tdb: api.sdk.Tdb, sdk: api.VerifiedSdk(.{ .tdb = tdb_specs })) !ResolvedT {
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

        pub fn getFieldMetadata(
            self: ResolvedT,
            comptime field: @EnumLiteral(),
            comptime static: bool,
            cache: *ManagedTypeCache,
            sdk: api.VerifiedSdk(.{ .field = field_specs, .type_definition = .all }),
        ) !*FieldMetadata {
            const Static = Field(@tagName(field), static);
            return (try Static.getMetadata(cache, self.type_def_metadata, .fo(sdk))).@"0";
        }

        fn asMethodThis(obj: anytype) ?*anyopaque {
            const ObjType = @TypeOf(obj);
            switch (ObjType) {
                api.sdk.ManagedObject => {
                    return obj.raw;
                },
                *api.sdk.ManagedObject => {
                    return obj.*.raw;
                },
                ValueType => {
                    return asMethodThis(obj.unsafeManaged());
                },
                else => {},
            }

            if (isManagedInterop(ObjType)) {
                return obj.managed.raw;
            }

            const obj_type_info = @typeInfo(ObjType);
            switch (obj_type_info) {
                .pointer => |p| {
                    if (p.child == ValueType) {
                        return asMethodThis(obj.unsafeManaged());
                    }
                    return @ptrCast(@alignCast(obj));
                },
                .optional => |o| {
                    if (o) |val| {
                        return asMethodThis(val);
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

        fn asFieldThisDetectManaged(obj: anytype) struct { *anyopaque, bool } {
            const ObjType = @TypeOf(obj);

            switch (ObjType) {
                api.sdk.ManagedObject => {
                    return .{ obj.raw, true };
                },
                *api.sdk.ManagedObject => {
                    return .{ obj.*.raw, true };
                },
                ValueType => {
                    return .{ obj.valuePtr(), false };
                },
                else => {},
            }

            if (isManagedInterop(ObjType)) {
                return .{ obj.managed.raw, true };
            }

            const isManagedObj = struct {
                inline fn func(comptime T: type) bool {
                    return isManagedInterop(T) or
                        T == api.sdk.ManagedObject or
                        T == @TypeOf((api.sdk.ManagedObject{ .raw = null }).raw);
                }
            }.func;
            if (isManagedObj(ObjType)) {
                return .{ obj.managed.raw, true };
            }

            const obj_type_info = @typeInfo(ObjType);
            switch (obj_type_info) {
                .pointer => |p| {
                    return .{
                        if (p.child == ValueType)
                            obj.valuePtr()
                        else if (isManagedInterop(p.child))
                            obj.managed.raw
                        else
                            @ptrCast(@alignCast(obj)),
                        isManagedObj(p.child),
                    };
                },
                else => {
                    @compileError("Concrete obj required!");
                },
            }
        }

        fn getTypeDefMetadata(
            cache: *ManagedTypeCache,
            tdb: api.sdk.Tdb,
            sdk: api.VerifiedSdk(.{ .tdb = tdb_specs }),
        ) !*TypeDefMetadata {
            return if (cached_metadata.load(.acquire)) |metadata| blk: {
                break :blk metadata;
            } else blk: {
                const type_def = tdb.findType(.fo(sdk), type_name) orelse return error.NoTypeDefFound;

                try cache.lock();
                defer cache.unlock();
                const new_metadata = try managed_type_cache.getOrCacheTypeDefMetadata(cache, type_def);
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
                    cache: *ManagedTypeCache,
                    type_def_metadata: *TypeDefMetadata,
                    sdk: api.VerifiedSdk(.{
                        .method = MethodMetadata.method_specs,
                        .type_definition = .all,
                    }),
                ) !*MethodMetadata {
                    return if (MethodT.cached_metadata.load(.acquire)) |metadata| blk: {
                        break :blk metadata;
                    } else blk: {
                        try cache.lock();
                        defer cache.unlock();
                        const method_metadata = try managed_type_cache.getOrCacheMethodMetadataTo(
                            cache,
                            type_def_metadata,
                            MethodT._sig,
                            .fo(sdk),
                        );

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
                    cache: *ManagedTypeCache,
                    type_def_metadata: *TypeDefMetadata,
                    sdk: api.VerifiedSdk(.{
                        .field = FieldMetadata.field_specs,
                        .type_definition = .all,
                    }),
                ) !struct { *FieldMetadata, bool } {
                    return if (FieldT.cached_metadata.load(.acquire)) |metadata| blk: {
                        break :blk .{ metadata.field_metadata, metadata.is_passed_type_valtype };
                    } else blk: {
                        try cache.lock();
                        defer cache.unlock();
                        const field_metadata = try managed_type_cache.getOrCacheFieldMetadataTo(
                            cache,
                            type_def_metadata,
                            FieldT._field_name,
                            .fo(sdk),
                        );

                        const is_passed_type_valtype = type_def_metadata.def.getVmObjType(.fo(sdk)) == .valtype;

                        // We use the cache arena, we want this to live as long as the cache itself.
                        const static_storage = try cache.cache_arena.allocator().create(FieldT);
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

        fn Instanced(ObjT: type) type {
            return struct {
                instance: ObjT,
                scope: Scoped,

                const InstanceT = @This();

                /// Wrapper around Scoped.call, see its documentation for details.
                pub inline fn call(
                    self: InstanceT,
                    comptime sig: [:0]const u8,
                    comptime RetType: type,
                    sdk: api.VerifiedSdk(.{
                        .method = method_specs,
                        .type_definition = .all,
                        .tdb = tdb_specs,
                    }),
                    args: anytype,
                ) !RetType {
                    return self.callWithInterops(sig, .{}, RetType, null, .fo(sdk), args);
                }

                /// Wrapper around Scoped.callWithInterops, see its documentation for details.
                pub inline fn callWithInterops(
                    self: InstanceT,
                    comptime sig: [:0]const u8,
                    comptime param_interops: anytype,
                    comptime RetType: type,
                    comptime rInterop: ?ToZigInterop(RetType),
                    sdk: api.VerifiedSdk(.{
                        .method = method_specs,
                        .type_definition = .all,
                        .tdb = tdb_specs,
                    }),
                    args: anytype,
                ) !RetType {
                    return self.scope.callWithInterops(self.instance, sig, param_interops, RetType, rInterop, .fo(sdk), args);
                }

                pub inline fn get(
                    self: InstanceT,
                    comptime field: @EnumLiteral(),
                    comptime T: type,
                    sdk: api.VerifiedSdk(.{
                        .field = field_specs,
                        .type_definition = .all,
                        .tdb = tdb_specs,
                    }),
                ) !T {
                    return self.getWithInterop(field, T, defaultToZigInterop(T), .fo(sdk));
                }

                pub inline fn getWithInterop(
                    self: InstanceT,
                    comptime field: @EnumLiteral(),
                    comptime T: type,
                    comptime interop: ToZigInterop(T),
                    sdk: api.VerifiedSdk(.{
                        .field = field_specs,
                        .type_definition = .all,
                        .tdb = tdb_specs,
                    }),
                ) !T {
                    return self.scope.getWithInterop(self.instance, field, T, interop, .fo(sdk));
                }

                pub inline fn set(
                    self: InstanceT,
                    comptime field: @EnumLiteral(),
                    sdk: api.VerifiedSdk(.{
                        .field = field_specs,
                        .type_definition = .all,
                        .tdb = tdb_specs,
                    }),
                    value: anytype,
                ) !void {
                    return self.setWithInterop(field, defaultFromZigInterop, .fo(sdk), value);
                }

                pub inline fn setWithInterop(
                    self: InstanceT,
                    comptime field: @EnumLiteral(),
                    comptime interop: FromZigInterop,
                    sdk: api.VerifiedSdk(.{
                        .field = field_specs,
                        .type_definition = .all,
                        .tdb = tdb_specs,
                    }),
                    value: anytype,
                ) !void {
                    return self.scope.setWithInterop(self.instance, field, interop, .fo(sdk), value);
                }
            };
        }

        const Scoped = struct {
            scope: *Scope,
            type_def_metadata: *TypeDefMetadata,

            const Self = @This();

            pub fn instanced(self: Self, obj: anytype) Instanced(@TypeOf(obj)) {
                return .{
                    .instance = obj,
                    .scope = self,
                };
            }

            fn callMethodWithInteropsImpl(
                self: Self,
                obj: anytype,
                comptime sig: [:0]const u8,
                comptime param_interops: anytype,
                comptime RetType: type,
                comptime rInterop: ?ToZigInterop(RetType),
                comptime static: bool,
                sdk: api.VerifiedSdk(.{
                    .method = method_specs,
                    .type_definition = .all,
                }),
                args: anytype,
            ) !RetType {
                const Static = Method(sig, param_interops, RetType, rInterop, static);
                const method_metadata = try Static.getMetadata(self.scope.cache, self.type_def_metadata, .fo(sdk));

                errdefer self.scope.cache.appendDiagnostics("method={s}", .{sig}) catch {};

                const retInterop = comptime Static._rInterop orelse defaultToZigInterop(Static._RetType);
                return try self.scope.invokeMethod(
                    asMethodThis(obj),
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
                    .method = method_specs,
                    .type_definition = .all,
                    .tdb = tdb_specs,
                }),
                args: anytype,
            ) !RetType {
                return self.callWithInterops(obj, sig, .{}, RetType, null, .fo(sdk), args);
            }

            /// Calls instance method with the given method signature on the provided object.
            /// Same as `Scope.callMethodWithInterops` but accepts comptime type name and method signature
            /// Stores them in a static struct to avoid redundant string allocations and comparisons on every call,
            /// so it's much faster when calling the same method multiple times.
            pub inline fn callWithInterops(
                self: Self,
                obj: anytype,
                comptime sig: [:0]const u8,
                comptime param_interops: anytype,
                comptime RetType: type,
                comptime rInterop: ?ToZigInterop(RetType),
                sdk: api.VerifiedSdk(.{
                    .method = method_specs,
                    .type_definition = .all,
                    .tdb = tdb_specs,
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
                    .method = method_specs,
                    .type_definition = .all,
                    .tdb = tdb_specs,
                }),
                args: anytype,
            ) !RetType {
                return self.callStaticMethodWithInterops(sig, .{}, RetType, null, .fo(sdk), args);
            }

            /// Same as `callMethodWithInterops` but for static methods, see its documentation for details.
            pub inline fn callStaticMethodWithInterops(
                self: Self,
                comptime sig: [:0]const u8,
                comptime param_interops: anytype,
                comptime RetType: type,
                comptime rInterop: ?ToZigInterop(RetType),
                sdk: api.VerifiedSdk(.{
                    .method = method_specs,
                    .type_definition = .all,
                    .tdb = tdb_specs,
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
                    .field = field_specs,
                    .type_definition = .all,
                    .tdb = tdb_specs,
                }),
            ) !T {
                const Static = Field(@tagName(field), static);
                const field_metadata, const is_passed_type_valtype = try Static.getMetadata(self.scope.cache, self.type_def_metadata, .fo(sdk));

                errdefer self.scope.cache.appendDiagnostics("field={s}", .{@tagName(field)}) catch {};

                if (comptime static) {
                    return try self.scope.readStaticField(field_metadata, T, interop, .fo(sdk));
                } else {
                    const obj_val, const passed_managed_obj = asFieldThisDetectManaged(obj);
                    return try self.scope.readField(
                        obj_val,
                        field_metadata,
                        T,
                        interop,
                        is_passed_type_valtype and !passed_managed_obj,
                        .fo(sdk),
                    );
                }
            }

            pub inline fn get(
                self: Self,
                obj: anytype,
                comptime field: @EnumLiteral(),
                comptime T: type,
                sdk: api.VerifiedSdk(.{
                    .field = field_specs,
                    .type_definition = .all,
                    .tdb = tdb_specs,
                }),
            ) !T {
                return self.getWithInterop(obj, field, T, defaultToZigInterop(T), .fo(sdk));
            }

            pub inline fn getWithInterop(
                self: Self,
                obj: anytype,
                comptime field: @EnumLiteral(),
                comptime T: type,
                comptime interop: ToZigInterop(T),
                sdk: api.VerifiedSdk(.{
                    .field = field_specs,
                    .type_definition = .all,
                    .tdb = tdb_specs,
                }),
            ) !T {
                return self.getFieldWithInteropImpl(obj, field, T, interop, false, .fo(sdk));
            }

            pub inline fn getStatic(
                self: Self,
                comptime field: @EnumLiteral(),
                comptime T: type,
                sdk: api.VerifiedSdk(.{
                    .field = field_specs,
                    .type_definition = .all,
                    .tdb = tdb_specs,
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
                    .field = field_specs,
                    .type_definition = .all,
                    .tdb = tdb_specs,
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
                    .field = field_specs,
                    .type_definition = .all,
                    .tdb = tdb_specs,
                }),
                value: anytype,
            ) !void {
                const Static = Field(@tagName(field), static);
                const field_metadata, const is_passed_type_valtype = try Static.getMetadata(self.scope.cache, self.type_def_metadata, .fo(sdk));

                errdefer self.scope.cache.appendDiagnostics("field={s}", .{@tagName(field)}) catch {};

                if (comptime static) {
                    return try self.scope.writeStaticField(field_metadata, interop, .fo(sdk), value);
                } else {
                    const obj_val, const passed_managed_obj = asFieldThisDetectManaged(obj);
                    return try self.scope.writeField(
                        obj_val,
                        field_metadata,
                        interop,
                        is_passed_type_valtype and !passed_managed_obj,
                        .fo(sdk),
                        value,
                    );
                }
            }

            pub inline fn set(
                self: Self,
                obj: anytype,
                comptime field: @EnumLiteral(),
                sdk: api.VerifiedSdk(.{
                    .field = field_specs,
                    .type_definition = .all,
                    .tdb = tdb_specs,
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
                    .field = field_specs,
                    .type_definition = .all,
                    .tdb = tdb_specs,
                }),
                value: anytype,
            ) !void {
                return self.setFieldWithInteropImpl(obj, field, interop, false, .fo(sdk), value);
            }

            pub inline fn setStatic(
                self: Self,
                comptime field: @EnumLiteral(),
                sdk: api.VerifiedSdk(.{
                    .field = field_specs,
                    .type_definition = .all,
                    .tdb = tdb_specs,
                }),
                value: anytype,
            ) !void {
                return self.setStaticWithInterop(field, defaultFromZigInterop, .fo(sdk), value);
            }

            pub inline fn setStaticWithInterop(
                self: Self,
                comptime field: @EnumLiteral(),
                comptime interop: FromZigInterop,
                sdk: api.VerifiedSdk(.{
                    .field = field_specs,
                    .type_definition = .all,
                    .tdb = tdb_specs,
                }),
                value: anytype,
            ) !void {
                return self.setFieldWithInteropImpl(null, field, interop, true, .fo(sdk), value);
            }
        };
    };
}
