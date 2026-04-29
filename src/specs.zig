const spec = @import("api/spec.zig");
pub const extend = spec.extend;
pub const merge = spec.merge;

pub const minimal = .{
    .functions = .all,
    .sdk = .{
        .functions = .{
            .get_managed_singleton,
            .get_tdb,
            .add_hook,
            .remove_hook,
            .create_managed_string,
            .create_managed_string_normal,
            .create_managed_array,
        },
        .managed_object = .{
            .get_type_definition,
            .add_ref,
            .release,
        },
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
        .tdb = .find_type,
        .type_definition = .all,
    },
};

pub const compact = .{
    .functions = .all,
    .sdk = .{
        .functions = .{
            .get_tdb,
            .get_resource_manager,
            .get_vm_context,
            .typeof_,
            .get_managed_singleton,
            .get_native_singleton,
            .create_managed_string,
            .create_managed_string_normal,
            .allocate,
            .deallocate,
            .add_hook,
            .remove_hook,
        },
        .field = .{
            .get_name,
            .get_type,
            .get_offset_from_base,
            .get_data_raw,
            .is_static,
        },
        .managed_object = .{
            .add_ref,
            .release,
            .get_type_definition,
            .get_ref_count,
        },
        .method = .{
            .invoke,
            .get_name,
            .get_return_type,
            .get_num_params,
            .get_params,
            .is_static,
        },
        .module = .{
            .get_module_name,
            .get_types,
            .get_num_types,
            .get_methods,
            .get_num_methods,
        },
        .reflection_method = .{
            .get_function,
        },
        .reflection_property = .{
            .is_static,
        },
        .resource = .all,
        .resource_manager = .all,
        .tdb = .all,
        .type_definition = .all,
        .type_info = .{
            .get_name,
            .get_type_definition,
            .is_singleton,
            .get_singleton_instance,
        },
        .vm_context = .all,
    },
};

test {
    @import("std").testing.refAllDecls(@This());
}
