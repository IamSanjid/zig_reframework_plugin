const std = @import("std");

pub const D3D = enum(u2) {
    dx11 = 1,
    dx12,
    /// Compile-time exposure of both backend modules.
    dx11_dx12,
};

const ReframeworkConfig = struct {
    d3d: ?D3D = null,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

const Owner = @This();

fn REFrameworkExamplesT(comptime examples: anytype) type {
    const ExamplesT = @TypeOf(examples);
    const info = @typeInfo(ExamplesT);
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("Needs a tuple compile value with only names.");
    }

    var field_names: [info.@"struct".fields.len + 1][]const u8 = undefined;
    var field_values: [field_names.len]u32 = undefined;
    for (info.@"struct".fields, 0..) |field, i| {
        const tag_name = @tagName(@field(examples, field.name));
        field_names[i] = tag_name;
        field_values[i] = @truncate(i);
    }
    field_names[info.@"struct".fields.len] = "all";
    field_values[info.@"struct".fields.len] = @truncate(info.@"struct".fields.len);

    const TagT = @Enum(u32, .nonexhaustive, &field_names, &field_values);
    return struct {
        const Tag = TagT;
        const default: Tag = @enumFromInt(0);

        fn build(tag: Tag, b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
            if (tag == .all) {
                inline for (@typeInfo(ExamplesT).@"struct".fields) |field| {
                    const tag_name = @tagName(@field(examples, field.name));
                    const builder = @field(Owner, tag_name ++ "_builder");
                    return builder(b, target, optimize);
                }
            } else {
                inline for (@typeInfo(ExamplesT).@"struct".fields) |field| {
                    const tag_name = @tagName(@field(examples, field.name));
                    if (tag == @field(Tag, tag_name)) {
                        const builder = @field(Owner, tag_name ++ "_builder");
                        return builder(b, target, optimize);
                    }
                }
            }
        }
    };
}

const REFrameworkExamples = REFrameworkExamplesT(.{
    .re9_basic,
    .re9_additional_save_slots,
    .re_imgui,
    .re_imgui_custom,
});

pub fn build(b: *std.Build) void {
    const example = b.option(
        REFrameworkExamples.Tag,
        "example",
        b.fmt("Choose which example plugin to build. Default: {s}", .{@tagName(REFrameworkExamples.default)}),
    ) orelse REFrameworkExamples.default;

    const d3d = b.option(D3D, "d3d", "Choose which Direct3D renderer surfaces to expose. dx11_dx12 exposes both modules at compile time.");
    const target = b.standardTargetOptions(.{
        .whitelist = &.{
            .{
                .os_tag = .windows,
                .os_version_min = .{ .windows = .win10_19h1 },
            },
        },
        .default_target = .{ .os_tag = .windows },
    });
    const optimize = b.standardOptimizeOption(.{});

    const mod = reframework(b, .{
        .d3d = d3d,
        .target = target,
        .optimize = optimize,
    }) orelse return;
    // simulating `std.Build.addModule`
    b.modules.put(b.graph.arena, b.dupe("reframework"), mod) catch @panic("OOM");

    REFrameworkExamples.build(example, b, target, optimize);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}

fn reframework(b: *std.Build, config: ReframeworkConfig) ?*std.Build.Module {
    const api_translate_c = b.addTranslateC(.{
        .root_source_file = b.path("reframework/include/reframework/API.h"),
        .target = config.target,
        .optimize = config.optimize,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = config.target,
        .optimize = config.optimize,
        .link_libc = true,
        .imports = &.{
            .{
                .name = "API",
                .module = api_translate_c.createModule(),
            },
        },
    });

    const build_options = b.addOptions();
    // TODO: Address this when the `std.Build.Options` printing optional Enum types issues has been resolved..
    build_options.addOption(u2, "D3D_NO_RENDERER", 0);
    build_options.addOption(u2, "D3D_DX11", @intFromEnum(D3D.dx11));
    build_options.addOption(u2, "D3D_DX12", @intFromEnum(D3D.dx12));
    build_options.addOption(u2, "D3D_DX11_DX12", @intFromEnum(D3D.dx11_dx12));

    if (config.d3d) |renderer| {
        const win32 = (b.lazyDependency("win32", .{}) orelse return null).module("win32");
        win32.resolved_target = config.target;
        win32.optimize = config.optimize;

        mod.addImport("win32", win32);

        switch (renderer) {
            .dx11 => {
                mod.linkSystemLibrary("d3d11", .{});
                // mod.linkSystemLibrary("d3dcsx");
            },
            .dx12 => {
                mod.linkSystemLibrary("d3d12", .{});
            },
            .dx11_dx12 => {
                mod.linkSystemLibrary("d3d11", .{});
                // mod.linkSystemLibrary("d3dcsx");
                mod.linkSystemLibrary("d3d12", .{});
            },
        }
        build_options.addOption(u2, "d3d", @intFromEnum(renderer));
        // mod.linkSystemLibrary("user32", .{});
        // mod.linkSystemLibrary("d3dcompiler_47", .{});
    } else {
        build_options.addOption(u2, "d3d", 0);
    }
    mod.addOptions("build_options", build_options);

    return mod;
}

fn re9_basic_builder(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const re9_basic_plugin = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "re9_basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/re9_basic/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "reframework",
                    .module = reframework(b, .{
                        .d3d = .dx11_dx12,
                        .target = target,
                        .optimize = optimize,
                    }) orelse return,
                },
            },
        }),
    });
    addReframeworkImGuiToExample(b, re9_basic_plugin);

    b.installArtifact(re9_basic_plugin);
}

fn re9_additional_save_slots_builder(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const re9_additional_save_slots_plugin = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "re9_additional_save_slots",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/re9_additional_save_slots/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "reframework",
                    .module = reframework(b, .{
                        .d3d = null,
                        .target = target,
                        .optimize = optimize,
                    }) orelse return,
                },
            },
        }),
    });

    b.installArtifact(re9_additional_save_slots_plugin);
}

fn re_imgui_builder(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const re_imgui_plugin = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "re_imgui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/re_imgui/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "reframework",
                    .module = reframework(b, .{
                        .d3d = null,
                        .target = target,
                        .optimize = optimize,
                    }) orelse return,
                },
            },
        }),
    });
    addReframeworkImGuiToExample(b, re_imgui_plugin);

    b.installArtifact(re_imgui_plugin);
}

fn re_imgui_custom_builder(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const re_imgui_custom_plugin = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "re_imgui_custom",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/re_imgui_custom/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "reframework",
                    .module = reframework(b, .{
                        .d3d = .dx11_dx12,
                        .target = target,
                        .optimize = optimize,
                    }) orelse return,
                },
            },
        }),
    });
    addImGuiToExample(b, re_imgui_custom_plugin);

    b.installArtifact(re_imgui_custom_plugin);
}

fn addReframeworkImGuiToExample(b: *std.Build, to: *std.Build.Step.Compile) void {
    const target = to.root_module.resolved_target orelse b.standardTargetOptions(.{
        .default_target = .{ .os_tag = .windows },
    });
    const optimize = to.root_module.optimize orelse b.standardOptimizeOption(.{});

    const win32 = (b.lazyDependency("win32", .{}) orelse return).module("win32");
    win32.resolved_target = target;
    win32.optimize = optimize;

    const cimgui = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("reframework/src/cimgui/cimgui.h"),
    });
    cimgui.defineCMacro("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", "1");

    to.root_module.addImport("cimgui", cimgui.createModule());
    to.root_module.addImport("win32", win32);
}

fn addImGuiToExample(b: *std.Build, to: *std.Build.Step.Compile) void {
    const cimguiGetConfig = @import("cimgui").getConfig;
    const target = to.root_module.resolved_target orelse b.standardTargetOptions(.{
        .default_target = .{ .os_tag = .windows },
    });
    const optimize = to.root_module.optimize orelse b.standardOptimizeOption(.{});

    const win32 = (b.lazyDependency("win32", .{}) orelse return).module("win32");
    win32.resolved_target = target;
    win32.optimize = optimize;

    const cimgui_dep = b.lazyDependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;
    const cimgui_conf = cimguiGetConfig(false);

    const cimgui_clib = cimgui_dep.artifact(cimgui_conf.clib_name);
    // imgui_clib.root_module.addCMacro("IMGUI_DISABLE_OBSOLETE_FUNCTIONS", "1");

    const cimgui = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = cimgui_dep.path(b.fmt("{s}/cimgui.h", .{cimgui_conf.include_dir})),
    });
    // imgui.defineCMacro("IMGUI_DISABLE_OBSOLETE_FUNCTIONS", "1");

    const imgui_c = b.addTranslateC(.{
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("src/examples/imgui_c.h"),
    });
    // imgui_c.defineCMacro("IMGUI_API", "__declspec(dllexport)");
    // imgui_c.defineCMacro("IMGUI_IMPL_API", "extern \"C\" __declspec(dllexport)");
    imgui_c.defineCMacro("TRANSLATE_C_DX11", null);
    imgui_c.defineCMacro("TRANSLATE_C_DX12", null);
    // imgui_c.defineCMacro("IMGUI_DISABLE_OBSOLETE_FUNCTIONS", "1");
    // imgui_c.addIncludePath(cimgui_dep.path(cimgui_conf.include_dir));
    // get our custom imgui.h
    imgui_c.addIncludePath(b.path("src/examples/"));
    imgui_c.addIncludePath(b.path("reframework/src/re2-imgui/"));

    const cflags = &.{
        "-fno-sanitize=undefined",
        "-Wno-elaborated-enum-base",
        "-Wno-error=date-time",
    };

    to.root_module.link_libcpp = target.result.abi != .msvc;
    to.root_module.addCMacro("IMGUI_API", "__declspec(dllexport)");
    to.root_module.addCMacro("IMGUI_IMPL_API", "extern \"C\" __declspec(dllexport)");
    // to.root_module.addCMacro("IMGUI_DISABLE_OBSOLETE_FUNCTIONS", "1");
    to.root_module.addIncludePath(cimgui_dep.path(cimgui_conf.include_dir));
    to.root_module.addIncludePath(b.path("reframework/src/re2-imgui/"));
    to.root_module.addCSourceFiles(.{
        .root = b.path("reframework/src/re2-imgui"),
        .files = &.{
            "imgui_impl_win32.cpp",
            "imgui_impl_dx11.cpp",
            "imgui_impl_dx12.cpp",
        },
        .flags = cflags,
        .language = .cpp,
    });

    to.root_module.addImport("cimgui", cimgui.createModule());
    to.root_module.addImport("win32", win32);
    to.root_module.addImport("imgui_c", imgui_c.createModule());

    to.root_module.linkLibrary(cimgui_clib);
    to.root_module.linkSystemLibrary("gdi32", .{});
    to.root_module.linkSystemLibrary("dwmapi", .{});
    to.root_module.linkSystemLibrary("d3dcompiler_47", .{});
}
