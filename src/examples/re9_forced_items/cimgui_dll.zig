const std = @import("std");

const win32 = @import("win32");
const cimgui = @import("cimgui");

const windows = std.os.windows;

pub var igSetCurrentContext: *const fn (ctx: ?*cimgui.ImGuiContext) callconv(.c) void = undefined;
pub var igSetAllocatorFunctions: *const fn (
    alloc_func: cimgui.ImGuiMemAllocFunc,
    free_func: cimgui.ImGuiMemFreeFunc,
    user_data: ?*anyopaque,
) callconv(.c) void = undefined;
pub var igDummy: *const fn (size: cimgui.ImVec2) callconv(.c) void = undefined;
pub var igSetNextItemOpen: *const fn (is_open: bool, cond: cimgui.ImGuiCond) callconv(.c) void = undefined;
pub var igCollapsingHeader_BoolPtr: *const fn (
    label: [*c]const u8,
    p_visible: [*c]bool,
    flags: cimgui.ImGuiTreeNodeFlags,
) callconv(.c) bool = undefined;
pub var igText: *const fn (fmt: [*c]const u8, ...) callconv(.c) void = undefined;
pub var igSeparatorText: *const fn (label: [*c]const u8) callconv(.c) void = undefined;
pub var igCheckbox: *const fn (label: [*c]const u8, v: [*c]bool) callconv(.c) bool = undefined;
pub var igSeparator: *const fn () callconv(.c) void = undefined;
pub var igSameLine: *const fn (offset_from_start_x: f32, spacing: f32) callconv(.c) void = undefined;
pub var igNewLine: *const fn () callconv(.c) void = undefined;
pub var igInputScalar: *const fn (
    label: [*c]const u8,
    data_type: c_int,
    p_data: ?*anyopaque,
    p_step: ?*const anyopaque,
    p_step_fast: ?*const anyopaque,
    format: [*c]const u8,
    flags: c_int,
) callconv(.c) bool = undefined;
pub var igButton: *const fn (label: [*c]const u8, size: cimgui.ImVec2) callconv(.c) bool = undefined;
pub var igPushStyleColor_U32: *const fn (idx: c_int, col: c_uint) callconv(.c) void = undefined;
pub var igPushStyleColor_Vec4: *const fn (idx: c_int, col: cimgui.ImVec4) callconv(.c) void = undefined;
pub var igPopStyleColor: *const fn (count: c_int) callconv(.c) void = undefined;
pub var igBeginTable: *const fn (str_id: [*c]const u8, columns: c_int, flags: c_int, outer_size: cimgui.ImVec2, inner_width: f32) callconv(.c) bool = undefined;
pub var igTableSetupColumn: *const fn (label: [*c]const u8, flags: c_int, init_width_or_weight: f32, user_id: c_uint) callconv(.c) void = undefined;
pub var igTableHeadersRow: *const fn () callconv(.c) void = undefined;
pub var igTableNextRow: *const fn (row_flags: c_int, min_row_height: f32) callconv(.c) void = undefined;
pub var igTableNextColumn: *const fn () callconv(.c) bool = undefined;
pub var igEndTable: *const fn () callconv(.c) void = undefined;
pub var igTableGetHoveredRow: *const fn () callconv(.c) c_int = undefined;
pub var igIsItemHovered: *const fn (flags: c_int) callconv(.c) bool = undefined;
pub var igSetTooltip: *const fn (fmt: [*c]const u8, ...) callconv(.c) void = undefined;
pub var igBegin: *const fn (name: [*c]const u8, p_open: [*c]bool, flags: c_int) callconv(.c) bool = undefined;
pub var igEnd: *const fn () callconv(.c) void = undefined;

var cimgui_dll_module: windows.HINSTANCE = undefined;

var initialized: bool = false;

const cimgui_dll_name = "cimgui.dll";
pub fn init() !void {
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
    igDummy = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igDummy") orelse
        return error.igDummyNotFound);
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
    igPushStyleColor_U32 = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igPushStyleColor_U32") orelse
        return error.igPushStyleColor_U32NotFound);
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
    igIsItemHovered = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igIsItemHovered") orelse
        return error.igIsItemHoveredNotFound);
    igSetTooltip = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igSetTooltip") orelse
        return error.igSetTooltipNotFound);
    igBegin = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igBegin") orelse
        return error.igBeginNotFound);
    igEnd = @ptrCast(win32.system.library_loader.GetProcAddress(cimgui_dll_module, "igEnd") orelse
        return error.igEndNotFound);

    initialized = true;
}
