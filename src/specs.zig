const spec = @import("api/spec.zig");
pub const extend = spec.extend;
pub const merge = spec.merge;

pub const minimal = .{
    .functions = .all,
    .sdk = .{
        .functions = .{
            .get_tdb,
            .get_vm_context,
            .get_resource_manager,
            .typeof_,
            .get_managed_singleton,
            .get_native_singleton,
            .add_hook,
            .remove_hook,
            .create_managed_string,
            .create_managed_string_normal,
            .create_managed_array,
        },
        .managed_object = .{
            .get_reflection_property_descriptor,
            .get_type_definition,
            .get_ref_count,
            .add_ref,
            .release,
            .is_managed_object,
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
        .type_info = .{
            .get_name,
            .get_type_definition,
            .get_reflection_property_descriptor,
        },
        .reflection_property = .all,
        .vm_context = .all,
        .resource_manager = .all,
        .resource = .all,
    },
};

pub const compact = .{
    .functions = .all,
    .sdk = .{
        .functions = .{
            .get_tdb,
            .get_vm_context,
            .get_resource_manager,
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
            .get_reflection_property_descriptor,
            .get_type_definition,
            .get_ref_count,
            .add_ref,
            .release,
            .is_managed_object,
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
        .tdb = .all,
        .type_definition = .all,
        .type_info = .all,
        .vm_context = .all,
        .resource = .all,
        .resource_manager = .all,
    },
};

test {
    @import("std").testing.refAllDecls(@This());
}
