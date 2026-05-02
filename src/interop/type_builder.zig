const std = @import("std");
const api = @import("../api.zig");
const type_utils = @import("../type_utils.zig");

const m = @import("metadata.zig");
const ManagedObjectMetadata = m.ManagedObjectMetadata;
const MethodMetadata = m.MethodMetadata;
const FieldMetadata = m.FieldMetadata;

const managed_type_cache = @import("managed_type_cache.zig");
const ManagedTypeCache = managed_type_cache.ManagedTypeCache;

const Scope = @import("Scope.zig");

const in = @import("../interop.zig");
const FromZigInterop = in.FromZigInterop;
const ToZigInterop = in.ToZigInterop;
const defaultToZigInterop = in.defaultToZigInterop;
const defaultFromZigInterop = in.defaultFromZigInterop;
const InteropSdk = in.InteropSdk;

pub inline fn isManagedInterop(T: type) bool {
    return type_utils.isPureStruct(T) and @hasField(T, "managed") and
        @hasField(T, "runtime") and @hasDecl(T, "Runtime") and
        @hasDecl(T.Runtime, "checkedInit");
}

fn ObjectCache(comptime full_type_name: [:0]const u8) type {
    return struct {
        const _full_type_name = full_type_name;
        var cached_metadata: std.atomic.Value(?*ManagedObjectMetadata) = .init(null);

        inline fn getMetadata() ?*ManagedObjectMetadata {
            if (cached_metadata.load(.acquire)) |metadata| {
                return metadata;
            }
            return null;
        }

        inline fn setMetadata(metadata: *ManagedObjectMetadata) void {
            cached_metadata.store(metadata, .release);
        }
    };
}

fn ManagedObject(comptime Builder: type) type {
    return struct {
        metadata: *ManagedObjectMetadata,

        pub const fullTypeName = Builder.fullTypeName;

        const ManagedObjectType = @This();
        const Cache = ObjectCache(fullTypeName());

        pub const Instance = struct {
            managed: api.sdk.ManagedObject,
            runtime: Runtime,

            const Self = @This();
            pub const Runtime = ManagedObjectType;

            pub fn init(cache: *ManagedTypeCache, sdk: InteropSdk, managed: api.sdk.ManagedObject) !Self {
                return checkedInit(cache, sdk, managed);
            }

            /// The provided sdk will be the userdata for each user-defined interop
            /// functions, we just won't have any compile-time checks for this.
            pub inline fn call(
                self: Self,
                comptime method: @EnumLiteral(),
                scope: *Scope,
                sdk: InteropSdk,
                args: anytype,
            ) !Builder.GetMethod(method, Instance).RetType {
                const Method = Builder.GetMethod(method, Instance);

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
                sdk: InteropSdk,
            ) !Builder.GetField(field, Instance).Type {
                const Field = Builder.GetField(field, Instance);
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
                sdk: InteropSdk,
                value: Builder.GetField(field, Instance).Type,
            ) !void {
                const Field = Builder.GetField(field, Instance);
                const field_metadata = self.runtime.metadata.fields[Field.Id];
                return scope.writeField(
                    self.managed.raw,
                    field_metadata,
                    Field.set,
                    false,
                    .fo(sdk),
                    value,
                );
            }

            pub inline fn callStatic(
                self: Self,
                comptime method: @EnumLiteral(),
                scope: *Scope,
                sdk: InteropSdk,
                args: anytype,
            ) !Builder.GetMethod(method, Instance).RetType {
                return self.runtime.callStatic(method, sdk, scope, args);
            }

            pub inline fn getStatic(
                self: Self,
                comptime field: @EnumLiteral(),
                scope: *Scope,
                sdk: InteropSdk,
            ) !Builder.GetField(field, Instance).Type {
                @setRuntimeSafety(false);
                return self.runtime.getStatic(field, sdk, scope);
            }

            pub inline fn setStatic(
                self: Self,
                comptime field: @EnumLiteral(),
                scope: *Scope,
                sdk: InteropSdk,
                value: Builder.GetField(field, Instance).Type,
            ) !void {
                return self.runtime.setStatic(field, scope, sdk, value);
            }

            pub const fullTypeName = Builder.fullTypeName;
        };

        pub fn get(cache: *ManagedTypeCache, sdk: InteropSdk.Extend(.{
            .functions = .{ .extend = .get_tdb },
            .tdb = .find_type,
        })) !ManagedObjectType {
            return blk: {
                if (Cache.getMetadata()) |metadata| {
                    break :blk ManagedObjectType{ .metadata = metadata };
                } else {
                    const tdb = api.sdk.getTdb(.fo(sdk)) orelse return error.TdbNull;
                    const type_def = tdb.findType(.fo(sdk), fullTypeName()) orelse return error.NoTypeDefFound;
                    break :blk checkedRuntime(cache, .fo(sdk), type_def);
                }
            };
        }

        pub fn getWithTdb(cache: *ManagedTypeCache, sdk: InteropSdk.Extend(.{ .tdb = .find_type }), tdb: api.sdk.Tdb) !ManagedObjectType {
            return blk: {
                if (Cache.getMetadata()) |metadata| {
                    break :blk ManagedObjectType{ .metadata = metadata };
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
            sdk: InteropSdk,
            args: anytype,
        ) !Builder.GetMethod(method, Instance).RetType {
            const Method = Builder.GetMethod(method, Instance);
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
            sdk: InteropSdk,
        ) !Builder.GetField(field, Instance).Type {
            @setRuntimeSafety(false);
            const Field = Builder.GetField(field, Instance);
            const field_metadata = self.metadata.fields[Field.Id];
            return scope.readStaticField(field_metadata, Field.Type, Field.get, .fo(sdk));
        }

        pub inline fn setStatic(
            self: ManagedObjectType,
            comptime field: @EnumLiteral(),
            scope: *Scope,
            sdk: InteropSdk,
            value: Builder.GetField(field, Instance).Type,
        ) !void {
            @setRuntimeSafety(false);
            const Field = Builder.GetField(field, Instance);
            const field_metadata = self.metadata.fields[Field.Id];
            return scope.writeStaticField(field_metadata, Field.set, .fo(sdk), value);
        }

        pub inline fn getMethod(self: ManagedObjectType, comptime method: @EnumLiteral()) api.sdk.Method {
            const Method = Builder.GetMethod(method, Instance);
            return self.metadata.methods[Method.Id].handle;
        }

        fn checkedInit(cache: *ManagedTypeCache, sdk: InteropSdk, managed: api.sdk.ManagedObject) !Instance {
            const runtime = blk: {
                if (Cache.getMetadata()) |metadata| {
                    break :blk ManagedObjectType{ .metadata = metadata };
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

        fn checkedRuntime(cache: *ManagedTypeCache, sdk: InteropSdk, type_def: api.sdk.TypeDefinition) !ManagedObjectType {
            const arena = cache.cache_arena.allocator();

            var collected_methods = try std.ArrayList(*MethodMetadata).initCapacity(arena, Builder.MethodList.MethodsLen);
            defer collected_methods.deinit(arena);

            var collected_fields = try std.ArrayList(*FieldMetadata).initCapacity(arena, Builder.FieldList.FieldsLen);
            defer collected_fields.deinit(arena);
            {
                try cache.lock();
                defer cache.unlock();

                // getting existing cached type_def metadata...
                const type_def_metdata = try managed_type_cache.getOrCacheTypeDefMetadata(cache, type_def);

                // Checking methods
                inline for (Builder.MethodList.Methods) |method_comptime_data| {
                    // TODO: Check param Types, Return Type for interoperability?
                    const method_cache_entry = try type_def_metdata.*.methods.getOrPut(method_comptime_data.InstantSignature);
                    if (method_cache_entry.found_existing) {
                        try collected_methods.append(arena, method_cache_entry.value_ptr.*);
                    } else {
                        // if we're removing on error, why not just not insert until we know it's valid?
                        // because it's a cold path, meaning these errors should happen rarely. otherwise,
                        // it's a user use case issue, they should be aware of what is available and what not.
                        errdefer type_def_metdata.*.methods.removeByPtr(method_cache_entry.key_ptr);

                        const method = type_def.findMethod(.fromOther(sdk), method_comptime_data.InstantSignature) orelse {
                            managed_type_cache.appendError(cache, "'" ++ method_comptime_data.InstantSignature ++ "' was not found in '" ++ fullTypeName() ++ "'") catch {};
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
                    const field_name = @tagName(field_comptime_data.InstantName);
                    const field_cache_entry = try type_def_metdata.*.fields.getOrPut(field_name);
                    if (field_cache_entry.found_existing) {
                        try collected_fields.append(arena, field_cache_entry.value_ptr.*);
                    } else {
                        errdefer type_def_metdata.*.fields.removeByPtr(field_cache_entry.key_ptr);

                        const field_handle = type_def.findField(.fo(sdk), field_name) orelse {
                            managed_type_cache.appendError(cache, "'" ++ field_name ++ "' was not found in '" ++ fullTypeName() ++ "'") catch {};
                            return error.FieldNotFound;
                        };
                        const field_type_def = field_handle.getType(.fo(sdk)) orelse {
                            managed_type_cache.appendError(cache, "'" ++ fullTypeName() ++ "." ++ field_name ++ "' doesn't have any valid Type Definition") catch {};
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
            ObjectCache(fullTypeName()).setMetadata(metadata);
            return .{ .metadata = metadata };
        }
    }.Instance;
}

pub fn ManagedObjectTypeBuilder(comptime full_type_name: [:0]const u8) type {
    return ManagedObjectTypeBuilderImpl(full_type_name, ManagedObjectTypeBuilderFields(0, .{}), ManagedObjectTypeBuilderMethods(0, .{}));
}

fn ManagedObjectTypeBuilderImpl(comptime full_type_name: [:0]const u8, comptime NewFieldList: type, comptime NewMethodList: type) type {
    return struct {
        const FieldList: type = NewFieldList;
        const MethodList: type = NewMethodList;

        const Builder = @This();

        fn GetField(comptime field: @EnumLiteral(), comptime Owner: type) type {
            for (0..FieldList.FieldsLen) |i| {
                if (field == FieldList.Fields[i].InstantName) {
                    return FieldList.Fields[i].Finalize(Owner);
                }
            }
            @compileError("No field decl was found with name: " ++ @tagName(field));
        }

        fn GetMethod(comptime method: @EnumLiteral(), comptime Owner: type) type {
            for (0..MethodList.MethodsLen) |i| {
                if (method == MethodList.Methods[i].InstantTag) {
                    return MethodList.Methods[i].Finalize(Owner);
                }
            }
            @compileError("No method decl was found with name: " ++ @tagName(method));
        }

        pub inline fn Build() type {
            return ManagedObject(@This());
        }

        pub fn Field(
            comptime field: @EnumLiteral(),
            comptime T: type,
            comptime get: anytype,
            comptime set: anytype,
        ) type {
            var fields: [FieldList.FieldsLen + 1]type = undefined;
            inline for (0..FieldList.FieldsLen) |i| {
                fields[i] = FieldList.Fields[i];
            }
            fields[FieldList.FieldsLen] = ManagedObjectTypeField(FieldList.FieldsLen, field, T, get, set);
            return ManagedObjectTypeBuilderImpl(full_type_name, ManagedObjectTypeBuilderFields(FieldList.FieldsLen + 1, fields), MethodList);
        }

        pub fn Method(
            comptime tag: @EnumLiteral(),
            comptime RetType: type,
            comptime rInterop: anytype,
        ) type {
            if (RetType == f32 and @typeInfo(@TypeOf(rInterop)) == .null) {
                // https://github.com/praydog/REFramework/blob/63dd83ead22bbab924b93bbd32e5be36d3a09a4d/src/mods/bindings/Sdk.cpp#L960
                // TODO: Use type full name?
                const retInterop = struct {
                    inline fn func(
                        sdk: *const anyopaque,
                        scope: *Scope,
                        from_type_def: api.sdk.TypeDefinition,
                        data: *?*anyopaque,
                    ) anyerror!RetType {
                        return @floatCast(defaultToZigInterop(f64)(sdk, scope, from_type_def, data));
                    }
                }.func;

                return ManagedObjectTypeMethodBuilder(@This(), MethodList.MethodsLen, null, tag, RetType, retInterop);
            } else {
                return ManagedObjectTypeMethodBuilder(@This(), MethodList.MethodsLen, null, tag, RetType, rInterop);
            }
        }

        pub fn MethodWithName(
            comptime name: [:0]const u8,
            comptime tag: @EnumLiteral(),
            comptime RetType: type,
            comptime rInterop: anytype,
        ) type {
            if (RetType == f32 and @typeInfo(@TypeOf(rInterop)) == .null) {
                // https://github.com/praydog/REFramework/blob/63dd83ead22bbab924b93bbd32e5be36d3a09a4d/src/mods/bindings/Sdk.cpp#L960
                // TODO: Use type full name?
                const retInterop = struct {
                    inline fn func(
                        sdk: *const anyopaque,
                        scope: *Scope,
                        from_type_def: api.sdk.TypeDefinition,
                        data: *?*anyopaque,
                    ) anyerror!RetType {
                        return @floatCast(defaultToZigInterop(f64)(sdk, scope, from_type_def, data));
                    }
                }.func;

                return ManagedObjectTypeMethodBuilder(@This(), MethodList.MethodsLen, name, tag, RetType, retInterop);
            } else {
                return ManagedObjectTypeMethodBuilder(@This(), MethodList.MethodsLen, name, tag, RetType, rInterop);
            }
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
    comptime getInterop: anytype,
    comptime setInterop: anytype,
) type {
    const getInterop_is_null = @typeInfo(@TypeOf(getInterop)) == .null;
    const setInterop_is_null = @typeInfo(@TypeOf(setInterop)) == .null;
    return struct {
        pub const InstantId = id;
        pub const InstantName: @EnumLiteral() = field;

        pub fn Finalize(comptime Owner: type) type {
            return if (T == ManagedObjectSelf) struct {
                pub const Id = InstantId;
                pub const Name = InstantName;
                pub const Type = Owner;
                pub const get: ToZigInterop(Owner) = if (getInterop_is_null) defaultToZigInterop(Owner) else getInterop;
                pub const set: FromZigInterop = if (setInterop_is_null) defaultFromZigInterop else setInterop;
            } else struct {
                pub const Id = InstantId;
                pub const Name = InstantName;
                pub const Type = T;
                pub const get: ToZigInterop(T) = if (getInterop_is_null) defaultToZigInterop(Type) else getInterop;
                pub const set: FromZigInterop = if (setInterop_is_null) defaultFromZigInterop else setInterop;
            };
        }
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
    comptime rInterop: anytype,
    comptime params_len: comptime_int,
    comptime params: [params_len]MethodParam,
) type {
    const rInterop_is_null = @typeInfo(@TypeOf(rInterop)) == .null;
    return struct {
        pub const InstantId = id;
        pub const InstantName = name orelse @tagName(tag);
        pub const InstantTag: @EnumLiteral() = tag;
        pub const InstantSignature = buildMethodSignatureParams(InstantName, &params);

        pub fn Finalize(Owner: type) type {
            var NParams: [params_len]MethodParam = params;
            inline for (0..params_len) |i| {
                if (NParams[i].type == ManagedObjectSelf) {
                    NParams[i].type = Owner;
                }
            }

            const FinalizeImpl = struct {
                fn func(NewParams: [params_len]MethodParam) type {
                    if (RType == ManagedObjectSelf) struct {
                        pub const Id = InstantId;
                        pub const Name = InstantName;
                        pub const Tag = InstantTag;
                        pub const RetType = Owner;
                        pub const retInterop: ToZigInterop(Owner) = if (rInterop_is_null) defaultToZigInterop(Owner) else rInterop;
                        pub const Params: [params_len]MethodParam = NewParams;
                        pub const ParamInterops = paramsInterops(params_len, Params);
                        pub const ParamInteropsTuple = paramInteropsTuple(params_len, Params);
                        pub const Signature = InstantSignature;
                    } else return struct {
                        pub const Id = InstantId;
                        pub const Name = InstantName;
                        pub const Tag = InstantTag;
                        pub const RetType = RType;
                        pub const retInterop: ToZigInterop(RType) = if (rInterop_is_null) defaultToZigInterop(RType) else rInterop;
                        pub const Params: [params_len]MethodParam = NewParams;
                        pub const ParamInterops = paramsInterops(params_len, Params);
                        pub const ParamInteropsTuple = paramInteropsTuple(params_len, Params);
                        pub const Signature = InstantSignature;
                    };
                }
            }.func;

            return FinalizeImpl(NParams);
        }
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
    comptime RetType: type,
    comptime retInterop: anytype,
) type {
    return ManagedObjectTypeMethodBuilderImpl(TypeBuilder, id, name, tag, RetType, retInterop, 0, .{});
}

fn ManagedObjectTypeMethodBuilderImpl(
    comptime TypeBuilder: type,
    comptime id: comptime_int,
    comptime name: ?[:0]const u8,
    comptime tag: @EnumLiteral(),
    comptime RetType: type,
    comptime retInterop: anytype,
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
            comptime get: anytype,
            comptime set: anytype,
        ) type {
            return BuildMethod().Field(field, T, get, set);
        }

        /// Builds current "Method", adds it to the parent "Type Builder" and returns it.
        fn BuildMethod() type {
            var methods: [TypeBuilder.MethodList.MethodsLen + 1]type = undefined;
            inline for (0..TypeBuilder.MethodList.MethodsLen) |i| {
                methods[i] = TypeBuilder.MethodList.Methods[i];
                if (methods[i].InstantTag == tag) {
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
            comptime newRetInterop: anytype,
        ) type {
            return BuildMethod().Method(new_tag, NewRetType, newRetInterop);
        }

        /// Builds current "Method" and returns a new "Method Builder"
        pub inline fn MethodWithName(
            comptime new_name: [:0]const u8,
            comptime new_tag: @EnumLiteral(),
            comptime NewRetType: type,
            comptime newRetInterop: anytype,
        ) type {
            return BuildMethod().MethodWithName(new_name, new_tag, NewRetType, newRetInterop);
        }
    };
}

/// Placeholder type to refer to the "self" type of the Managed Object in fields and methods declaration,
/// will be replaced with the actual type during the build.
pub const ManagedObjectSelf = struct {};

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

const MethodParam = struct {
    type_name: ?[:0]const u8 = null,
    type: type,
    comptime interop: FromZigInterop = defaultFromZigInterop,
};

test "builder" {
    const FooBuilder = ManagedObjectTypeBuilder("app.foo")
        .Field(.Test, i32, null, null)
        .Field(.Test2, f32, null, null)
        .Method(.TestMethod, void, null)
        .Method(.TestMethod2, void, null)
        .Param("System.Int32", i32, null)
        .Param("System.Int32", i32, null)
        .BuildMethod();

    const Foo = FooBuilder.Build();
    try std.testing.expectEqual(std.hash_map.hashString("app.foo"), std.hash_map.hashString(Foo.Runtime.fullTypeName()));

    try std.testing.expect(comptime FooBuilder.FieldList.FieldsLen == 2);
    try std.testing.expect(comptime FooBuilder.FieldList.Fields[0].Finalize(Foo).Type == i32);
    try std.testing.expectEqualStrings("Test", @tagName(FooBuilder.FieldList.Fields[0].Finalize(Foo).Name));
    try std.testing.expectEqualStrings("Test2", @tagName(FooBuilder.FieldList.Fields[1].Finalize(Foo).Name));
    try std.testing.expectEqualStrings("TestMethod", FooBuilder.MethodList.Methods[0].Finalize(Foo).Name);
    try std.testing.expect(comptime FooBuilder.MethodList.Methods[0].Finalize(Foo).RetType == void);
    try std.testing.expectEqualStrings("TestMethod2", FooBuilder.MethodList.Methods[1].Finalize(Foo).Name);
    try std.testing.expectEqualStrings("TestMethod2(System.Int32, System.Int32)", FooBuilder.MethodList.Methods[1].Finalize(Foo).Signature);
    try std.testing.expect(comptime FooBuilder.MethodList.Methods[1].Finalize(Foo).Params[0].type == i32);
    try std.testing.expect(comptime FooBuilder.MethodList.Methods[1].Finalize(Foo).Params[1].type == i32);

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
