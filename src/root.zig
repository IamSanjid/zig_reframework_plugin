const std = @import("std");
pub const build_options = @import("build_options");

pub const API_C = @import("API");
pub const d3d_renderer = if (build_options.d3d_renderer != build_options.D3D_NO_RENDERER)
    @import("d3d_renderer.zig")
else
    struct {};

pub const api = @import("api.zig");
pub const sdk = api.sdk;
pub const Api = api.Api;

pub const interop = @import("interop.zig");

const type_utils = @import("api/type_utils.zig");

pub const PluginVersion = struct {
    gameName: ?[:0]const u8 = null,
    major: u32,
    minor: u32,
    patch: u32,

    pub const default: @This() = .{
        .gameName = null,
        .major = API_C.REFRAMEWORK_PLUGIN_VERSION_MAJOR,
        .minor = API_C.REFRAMEWORK_PLUGIN_VERSION_MINOR,
        .patch = API_C.REFRAMEWORK_PLUGIN_VERSION_PATCH,
    };

    pub fn from(gameName: ?[:0]const u8, semantic: std.SemanticVersion) @This() {
        .{
            .gameName = gameName,
            .major = semantic.major,
            .minor = semantic.minor,
            .patch = semantic.patch,
        };
    }
};

pub inline fn initPlugin(
    init: anytype,
    comptime options: struct {
        requiredVersion: PluginVersion = .default,
        onPresent: ?fn () void = null,
        onDeviceReset: ?fn () void = null,
    },
) void {
    const CWrapped = struct {
        fn initialize(init_param: [*c]const API_C.REFrameworkPluginInitializeParam) callconv(.c) bool {
            const api_instance = Api.init(init_param) catch return false;

            if (options.onPresent) |f| {
                if (!api_instance.param.safe().functions.safe().on_present(&struct {
                    fn func(...) callconv(.c) void {
                        return f();
                    }
                }.func)) {
                    api_instance.logError("Failed to set onPresent callback!", .{});
                }
            }

            if (options.onDeviceReset) |f| {
                if (!api_instance.param.safe().functions.safe().on_device_reset(&struct {
                    fn func(...) callconv(.c) void {
                        return f();
                    }
                }.func)) {
                    api_instance.logError("Failed to set onDeviceReset callback!", .{});
                }
            }

            const T = @TypeOf(init);
            const info = @typeInfo(T);

            if (info != .@"fn") @compileError("expected a function, got " ++ @typeName(T));

            const fn_info = info.@"fn";

            if (fn_info.params.len != 1) @compileError(std.fmt.comptimePrint(
                "init must accept exactly 1 parameter ({s}), got {}",
                .{ @typeName(Api), fn_info.params.len },
            ));

            const param = fn_info.params[0];
            const param_type = param.type orelse
                @compileError("handler parameter must be a concrete type, not anytype");

            if (param_type != Api) @compileError(
                "init parameter must be " ++ @typeName(Api) ++ ", got " ++ @typeName(param_type),
            );

            if (fn_info.return_type) |ret| {
                switch (@typeInfo(ret)) {
                    .void => {
                        init(api_instance);
                        return true;
                    },
                    .error_union => |eu| {
                        if (eu.payload != void) @compileError(
                            "init error union payload must be void, got " ++ @typeName(eu.payload),
                        );
                        init(api_instance) catch |e| {
                            api_instance.logError("Failed to initialize error: %s", .{@errorName(e).ptr});
                            return false;
                        };
                        return true;
                    },
                    else => @compileError(
                        "init return type must be void or E!void, got " ++ @typeName(ret),
                    ),
                }
            } else {
                init(api_instance);
                return true;
            }
        }

        fn requiredVersion(version_res: [*c]API_C.REFrameworkPluginVersion) callconv(.c) void {
            const version: *API_C.REFrameworkPluginVersion = @ptrCast(version_res orelse return);
            version.major = @intCast(options.requiredVersion.major);
            version.minor = @intCast(options.requiredVersion.minor);
            version.patch = @intCast(options.requiredVersion.patch);
            if (options.requiredVersion.gameName) |gameName| {
                version.game_name = gameName.ptr;
            }
        }
    };

    @export(&CWrapped.initialize, .{
        .name = "reframework_plugin_initialize",
        .linkage = .strong,
    });
    @export(&CWrapped.requiredVersion, .{
        .name = "reframework_plugin_required_version",
        .linkage = .strong,
    });
}

test {
    std.testing.refAllDecls(@This());
}
