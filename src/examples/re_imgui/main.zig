const std = @import("std");
const re = @import("reframework");
const win32 = @import("win32");

const cimgui = @import("cimgui");

const windows = std.os.windows;

const interop = re.interop;

var g_api: re.Api = undefined;

fn init(api: re.api.Api) !void {
    g_api = api;
}

/// There are two ways to use REFramewrork's ImGui rendering in a plugin:
/// 1. REFramework usually compiles with cimgui bindings, and it allows us to "LoadLibraryExW"
///   the cimgui.dll and call its functions directly. This is what this example demonstrates.
/// 2. We can compile the same ImGui and cimgui version from source, the REFramework uses, with the same
///   ImGui config, usually set through `re2_imconfig.hpp`, and then we can link with the compiled
///   library and directly call the functions without "LoadLibraryExW". This is more efficient, but it requires
///   us to maintain the same ImGui version and config as REFramework, and needs an extra "freetype" dependency.
const cimgui_dll = struct {
    var igSetCurrentContext: *const fn (ctx: ?*cimgui.ImGuiContext) callconv(.c) void = undefined;
    var igSetAllocatorFunctions: *const fn (
        alloc_func: cimgui.ImGuiMemAllocFunc,
        free_func: cimgui.ImGuiMemFreeFunc,
        user_data: ?*anyopaque,
    ) callconv(.c) void = undefined;
    var igSetNextItemOpen: *const fn (is_open: bool, cond: cimgui.ImGuiCond) callconv(.c) void = undefined;
    var igCollapsingHeader_BoolPtr: *const fn (
        label: [*c]const u8,
        p_visible: [*c]bool,
        flags: cimgui.ImGuiTreeNodeFlags,
    ) callconv(.c) bool = undefined;
    var igText: *const fn (fmt: [*c]const u8, ...) callconv(.c) void = undefined;

    var cimgui_dll_module: windows.HINSTANCE = undefined;

    var initialized: bool = false;

    const cimgui_dll_name = "cimgui.dll";
    fn init() !void {
        if (initialized) return;

        cimgui_dll_module = win32.system.library_loader.LoadLibraryExW(
            std.unicode.utf8ToUtf16LeStringLiteral(cimgui_dll_name),
            null,
            .{},
        ) orelse return error.LoadLibraryFailed;

        igSetCurrentContext = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igSetCurrentContext") orelse
            return error.GetProcAddressFailed);
        igSetAllocatorFunctions = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igSetAllocatorFunctions") orelse
            return error.GetProcAddressFailed);
        igSetNextItemOpen = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igSetNextItemOpen") orelse
            return error.GetProcAddressFailed);
        igCollapsingHeader_BoolPtr = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igCollapsingHeader_BoolPtr") orelse
            return error.GetProcAddressFailed);
        igText = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igText") orelse
            return error.GetProcAddressFailed);

        initialized = true;
    }
};

fn onImGuiDrawUI(data: *re.API_C.REFImGuiFrameCbData) void {
    @setRuntimeSafety(false);

    cimgui_dll.init() catch |e| {
        g_api.logError("Failed to initialize cimgui.dll: %s", .{@as([*:0]const u8, @errorName(e))});
        return;
    };

    cimgui_dll.igSetCurrentContext(@ptrCast(@alignCast(data.context)));
    cimgui_dll.igSetAllocatorFunctions(
        @ptrCast(@alignCast(data.malloc_fn)),
        @ptrCast(@alignCast(data.free_fn)),
        data.user_data,
    );

    cimgui_dll.igSetNextItemOpen(false, cimgui.ImGuiCond_FirstUseEver);
    if (!cimgui_dll.igCollapsingHeader_BoolPtr("Hello from Zig!", null, 0)) {
        return;
    }
    _ = cimgui_dll.igText("This is an example of using ImGui in a REFramework plugin written in Zig.");
    _ = cimgui_dll.igText("This uses REFramework's ImGui rendering, we don't need to implement our own renderer logic.");
}

comptime {
    re.initPlugin(init, .{
        .onImGuiDrawUI = onImGuiDrawUI,
    });
}
