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
                    scope: *Scope,
                    type_def_metadata: *TypeDefMetadata,
                    sdk: api.VerifiedSdk(.{
                        .method = MethodMetadata.method_specs,
                        .type_definition = .all,
                    }),
                ) !*MethodMetadata {
                    return if (MethodT.cached_metadata.load(.acquire)) |metadata| blk: {
                        break :blk metadata;
                    } else blk: {
                        try scope.cache.lock();
                        defer scope.cache.unlock();
                        const method_metadata = try managed_type_cache.getOrCacheMethodMetadataTo(
                            scope.cache,
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
                    scope: *Scope,
                    type_def_metadata: *TypeDefMetadata,
                    sdk: api.VerifiedSdk(.{
                        .field = FieldMetadata.field_specs,
                        .type_definition = .all,
                    }),
                ) !struct { *FieldMetadata, bool } {
                    return if (FieldT.cached_metadata.load(.acquire)) |metadata| blk: {
                        break :blk .{ metadata.field_metadata, metadata.is_passed_type_valtype };
                    } else blk: {
                        try scope.cache.lock();
                        defer scope.cache.unlock();
                        const field_metadata = try managed_type_cache.getOrCacheFieldMetadataTo(
                            scope.cache,
                            type_def_metadata,
                            FieldT._field_name,
                            .fo(sdk),
                        );

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
                    .method = method_specs,
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
            pub fn callWithInterops(
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
            pub fn callStaticMethodWithInterops(
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
                    .field = field_specs,
                    .type_definition = .all,
                    .tdb = tdb_specs,
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

            pub fn setStaticWithInterop(
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
