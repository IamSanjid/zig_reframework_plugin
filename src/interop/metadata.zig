const std = @import("std");
const api = @import("../api.zig");

pub const MethodMetadata = struct {
    handle: api.sdk.Method,
    ret_type_def: api.sdk.TypeDefinition,
    param_type_defs: []api.sdk.TypeDefinition,

    const Self = @This();

    pub const method_specs = .{
        .get_return_type,
        .get_num_params,
        .get_params,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        sdk: api.VerifiedSdk(.{
            .method = method_specs,
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

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.param_type_defs);
    }
};

pub const invalid_offset: usize = std.math.maxInt(usize);

// https://github.com/praydog/REFramework/blob/ce9df1fe81e897c117d85ac9c4446a1a453b938f/shared/sdk/RETypeDefinition.cpp#L434
pub const FieldMetadata = struct {
    handle: api.sdk.Field,
    type_def: api.sdk.TypeDefinition,
    offset: usize = invalid_offset,

    pub const field_specs = .get_type;
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

    pub fn init(allocator: std.mem.Allocator, def: api.sdk.TypeDefinition) @This() {
        return .{ .methods = .init(allocator), .fields = .init(allocator), .def = def };
    }
};
