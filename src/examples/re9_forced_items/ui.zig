const std = @import("std");

const re = @import("reframework");

const win32 = @import("win32");
const cimgui = @import("cimgui");

const windows = std.os.windows;

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
    var igSeparatorText: *const fn (label: [*c]const u8) callconv(.c) void = undefined;
    var igCheckbox: *const fn (label: [*c]const u8, v: [*c]bool) callconv(.c) bool = undefined;
    var igSeparator: *const fn () callconv(.c) void = undefined;
    var igSameLine: *const fn (offset_from_start_x: f32, spacing: f32) callconv(.c) void = undefined;
    var igInputScalar: *const fn (
        label: [*c]const u8,
        data_type: c_int,
        p_data: ?*anyopaque,
        p_step: ?*const anyopaque,
        p_step_fast: ?*const anyopaque,
        format: [*c]const u8,
        flags: c_int,
    ) callconv(.c) bool = undefined;
    var igButton: *const fn (label: [*c]const u8, size: cimgui.ImVec2) callconv(.c) bool = undefined;

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
            return error.igSetCurrentContextNotFound);
        igSetAllocatorFunctions = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igSetAllocatorFunctions") orelse
            return error.igSetAllocatorFunctionsNotFound);
        igSetNextItemOpen = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igSetNextItemOpen") orelse
            return error.igSetNextItemOpenNotFound);
        igCollapsingHeader_BoolPtr = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igCollapsingHeader_BoolPtr") orelse
            return error.igCollapsingHeader_BoolPtrNotFound);
        igText = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igText") orelse
            return error.igTextNotFound);
        igSeparatorText = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igSeparatorText") orelse
            return error.igSeparatorTextNotFound);
        igCheckbox = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igCheckbox") orelse
            return error.igCheckboxNotFound);
        igSeparator = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igSeparator") orelse
            return error.igSeparatorNotFound);
        igSameLine = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igSameLine") orelse
            return error.igSameLineNotFound);
        igInputScalar = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igInputScalar") orelse
            return error.igInputInt2NotFound);
        igButton = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igButton") orelse
            return error.igButtonNotFound);

        initialized = true;
    }
};

pub fn draw(data: *re.API_C.REFImGuiFrameCbData) !void {
    cimgui_dll.init() catch |e| {
        std.log.err("Dynamic cimgui initialization failed: {}", .{e});
        return;
    };

    cimgui_dll.igSetCurrentContext(@ptrCast(@alignCast(data.context)));
    cimgui_dll.igSetAllocatorFunctions(
        @ptrCast(@alignCast(data.malloc_fn)),
        @ptrCast(@alignCast(data.free_fn)),
        data.user_data,
    );
}
