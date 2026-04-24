# Zig REFramework Plugin

Zig wrapper for [REFramework](https://github.com/praydog/REFramework) plugin.

## Usage

Fetch:
```sh
zig fetch --save https://github.com/iamsanjid/zig_reframework_plugin.git
```

Add as module:
```zig
const reframework = b.dependency("reframework").module("reframework");
exe.root_module.addImport("reframework", reframework);
```

Recommended DLL build configuration:
```zig
b.addLibrary(.{
    .linkage = .dynamic,
    .name = "your_plugin_name",
    .root_module = b.createModule(.{
        .root_source_file = b.path("<path_to_root_source_file>"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "reframework", .module = reframework },
        },
    }),
})
```

REFramework ImGui rendering with dynamic cimgui loading:
```zig
const win32 = b.dependency("win32", .{}).module("win32");
win32.resolved_target = target;
win32.optimize = optimize;

// Grab cimgui.h from the REFramework Repo usually in: https://github.com/praydog/REFramework/tree/master/src/cimgui
const cimgui = b.addTranslateC(.{
    .target = target,
    .optimize = optimize,
    .root_source_file = b.path("<path_to>/cimgui.h"),
});
cimgui.defineCMacro("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", "1");

const plugin = b.addLibrary(.{
    .linkage = .dynamic,
    .name = "your_plugin_name",
    .root_module = b.createModule(.{
        .root_source_file = b.path("<path_to_root_source_file>"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "reframework", .module = reframework },
            .{ .name = "win32", .module = win32 },
            .{ .name = "cimgui", .module = cimgui },
        },
    }),
});
```

Check `build.zig` for more build configurations.

## Build

Build all examples:
```sh
zig build -Dexample=all
```

Run available tests:
```sh
zig build test
```

# LICENSE
MIT