const std = @import("std");

const re = @import("reframework");

const win32 = @import("win32");
const cimgui = @import("cimgui");

const windows = std.os.windows;

const g = @import("root").g;

const log = std.log.scoped(.re9_forced_items_ui);

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
    var igNewLine: *const fn () callconv(.c) void = undefined;
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
    var igPushStyleColor_Vec4: *const fn (idx: c_int, col: cimgui.ImVec4) callconv(.c) void = undefined;
    var igPopStyleColor: *const fn (count: c_int) callconv(.c) void = undefined;
    var igBeginTable: *const fn (str_id: [*c]const u8, columns: c_int, flags: c_int, outer_size: cimgui.ImVec2, inner_width: f32) callconv(.c) bool = undefined;
    var igTableSetupColumn: *const fn (label: [*c]const u8, flags: c_int, init_width_or_weight: f32, user_id: c_uint) callconv(.c) void = undefined;
    var igTableHeadersRow: *const fn () callconv(.c) void = undefined;
    var igTableNextRow: *const fn (row_flags: c_int, min_row_height: f32) callconv(.c) void = undefined;
    var igTableNextColumn: *const fn () callconv(.c) bool = undefined;
    var igEndTable: *const fn () callconv(.c) void = undefined;

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
        igNewLine = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igNewLine") orelse
            return error.igNewLineNotFound);
        igInputScalar = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igInputScalar") orelse
            return error.igInputInt2NotFound);
        igButton = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igButton") orelse
            return error.igButtonNotFound);
        igPushStyleColor_Vec4 = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igPushStyleColor_Vec4") orelse
            return error.igPushStyleColor_Vec4NotFound);
        igPopStyleColor = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igPopStyleColor") orelse
            return error.igPopStyleColorNotFound);
        igBeginTable = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igBeginTable") orelse
            return error.igBeginTableNotFound);
        igTableSetupColumn = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igTableSetupColumn") orelse
            return error.igTableSetupColumnNotFound);
        igTableHeadersRow = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igTableHeadersRow") orelse
            return error.igTableHeadersRowNotFound);
        igTableNextRow = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igTableNextRow") orelse
            return error.igTableNextRowNotFound);
        igTableNextColumn = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igTableNextColumn") orelse
            return error.igTableNextColumnNotFound);
        igEndTable = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igEndTable") orelse
            return error.igEndTableNotFound);

        initialized = true;
    }
};

pub fn draw(data: *re.API_C.REFImGuiFrameCbData) !void {
    cimgui_dll.init() catch |e| {
        log.err("Dynamic cimgui initialization failed: {}", .{e});
        return;
    };

    cimgui_dll.igSetCurrentContext(@ptrCast(@alignCast(data.context)));
    cimgui_dll.igSetAllocatorFunctions(
        @ptrCast(@alignCast(data.malloc_fn)),
        @ptrCast(@alignCast(data.free_fn)),
        data.user_data,
    );

    cimgui_dll.igSetNextItemOpen(false, cimgui.ImGuiCond_FirstUseEver);
    if (!cimgui_dll.igCollapsingHeader_BoolPtr("RE9 Forced Items in Zig", null, 0)) {
        return;
    }

    g.api.lockLua();
    defer g.api.unlockLua();

    if (g.items.catalog.count() == 0) {
        cimgui_dll.igText("No item info found. Please reload/load a save-data.");
        return;
    }

    cimgui_dll.igText("Found %u items.", g.items.catalog.count());
}
