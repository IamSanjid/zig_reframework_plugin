const std = @import("std");
const api = @import("../api.zig");

const metadata = @import("metadata.zig");
const TypeDefMetadata = metadata.TypeDefMetadata;
const MethodMetadata = metadata.MethodMetadata;
const FieldMetadata = metadata.FieldMetadata;

const resolved_type = @import("resolved_type.zig");
const ResolvedType = resolved_type.ResolvedType;

const Scope = @import("Scope.zig");

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

    pub inline fn getOrCacheMethodMetadata(
        self: *Self,
        sdk: api.VerifiedSdk(.{
            .method = MethodMetadata.method_specs,
            .type_definition = .all,
        }),
        type_def: api.sdk.TypeDefinition,
        sig: [:0]const u8,
    ) !*MethodMetadata {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const type_def_metadata = try getOrCacheTypeDefMetadata(self, type_def);
        return getOrCacheMethodMetadataTo(self, type_def_metadata, sig, .fo(sdk));
    }

    pub inline fn getOrCacheFieldMetadata(
        self: *Self,
        sdk: api.VerifiedSdk(.{
            .field = FieldMetadata.field_specs,
            .type_definition = .all,
        }),
        type_def: api.sdk.TypeDefinition,
        field_name: [:0]const u8,
    ) !*FieldMetadata {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const type_def_metadata = try getOrCacheTypeDefMetadata(self, type_def);
        return getOrCacheFieldMetadataTo(self, type_def_metadata, field_name, .fo(sdk));
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
};

pub fn getOrCacheTypeDefMetadata(
    type_cache: *ManagedTypeCache,
    type_def: api.sdk.TypeDefinition,
) !*TypeDefMetadata {
    const arena = type_cache.cache_arena.allocator();

    const type_def_entry = try type_cache.type_def_map.getOrPut(arena, type_def);
    if (!type_def_entry.found_existing) {
        const type_def_metadata = try arena.create(TypeDefMetadata);
        type_def_metadata.* = TypeDefMetadata.init(arena, type_def);
        type_def_entry.value_ptr.* = type_def_metadata;
    }

    return type_def_entry.value_ptr.*;
}

pub fn getOrCacheMethodMetadataTo(
    type_cache: *ManagedTypeCache,
    type_def_metadata: *TypeDefMetadata,
    sig: [:0]const u8,
    sdk: api.VerifiedSdk(.{
        .method = MethodMetadata.method_specs,
        .type_definition = .all,
    }),
) !*MethodMetadata {
    const arena = type_cache.cache_arena.allocator();

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

pub fn getOrCacheFieldMetadataTo(
    type_cache: *ManagedTypeCache,
    type_def_metadata: *TypeDefMetadata,
    field_name: [:0]const u8,
    sdk: api.VerifiedSdk(.{
        .field = FieldMetadata.field_specs,
        .type_definition = .all,
    }),
) !*FieldMetadata {
    const arena = type_cache.cache_arena.allocator();

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

pub fn appendError(self: *ManagedTypeCache, err: []const u8) !void {
    const arena = self.value_arena.allocator();
    try self.diagnostics.appendSlice(arena, err);
    try self.diagnostics.append(arena, '\n');
}
