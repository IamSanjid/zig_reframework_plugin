const std = @import("std");

const re = @import("reframework");

const win32 = @import("win32");
const cimgui = @import("cimgui");
const imgui_c = @import("imgui_c");

const d3d12_imgui_render = @import("d3d12_imgui_render.zig");
const d3d11_imgui_render = @import("d3d11_imgui_render.zig");

const windows = std.os.windows;

const d3d = re.d3d;

const g = struct {
    var api: re.api.Api = undefined;
    var allocator: std.mem.Allocator = undefined;
    var io: std.Io = undefined;
    var hwnd: windows.HWND = undefined;
    var renderer_type: re.api.RendererType = undefined;
    var param: re.api.VerifiedParam(.{ .renderer_data = .{.renderer_type} }) = undefined;

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    var threaded: std.Io.Threaded = undefined;

    fn init(init_api: re.Api) !void {
        api = init_api;

        param = try api.verifiedParam(.{ .renderer_data = .{.renderer_type} });
        renderer_type = .fromU32(@intCast(param.safe().renderer_data.safe().renderer_type));
    }

    fn attach() void {
        threaded = .init(debug_allocator.allocator(), .{});
        allocator = debug_allocator.allocator();
        io = threaded.io();
    }

    fn reset() void {
        threaded.deinit();
        _ = debug_allocator.detectLeaks();
        _ = debug_allocator.deinit();
    }
};

pub fn pluginLog(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const log_msg = std.fmt.allocPrintSentinel(
        g.allocator,
        (if (scope != .default) ("(" ++ @tagName(scope) ++ "): ") else "") ++ format,
        args,
        0,
    ) catch return;
    defer g.allocator.free(log_msg);
    switch (message_level) {
        .err => g.api.logError("%s", .{log_msg.ptr}),
        .warn => g.api.logWarn("%s", .{log_msg.ptr}),
        else => g.api.logInfo("%s", .{log_msg.ptr}),
    }
}

pub const std_options: std.Options = .{
    .logFn = pluginLog,
};

const log = std.log.scoped(.re_imgui_custom);

fn init(api: re.Api) !void {
    g.api = api;

    log.info(
        "RE ImGui example with custom renderer! Required REFramework Version: {}.{}.{}",
        .{
            re.PluginVersion.default.major,
            re.PluginVersion.default.minor,
            re.PluginVersion.default.patch,
        },
    );
}

var imgui_initialized: bool = false;

fn initImGui() !void {
    if (imgui_initialized) return;

    if (!cimgui.igDebugCheckVersionAndDataLayout(
        cimgui.IMGUI_VERSION,
        @sizeOf(cimgui.ImGuiIO),
        @sizeOf(cimgui.ImGuiStyle),
        @sizeOf(cimgui.ImVec2),
        @sizeOf(cimgui.ImVec4),
        @sizeOf(cimgui.ImDrawVert),
        @sizeOf(cimgui.ImDrawIdx),
    )) {
        return error.ImGuiVersionCheckFailed;
    }
    if (cimgui.igCreateContext(null) == null) return error.ImGuiCreateContextFailed;

    cimgui.igGetIO().*.IniFilename = "re_imgui_custom.ini";
    cimgui.igGetIO().*.ConfigFlags |= cimgui.ImGuiConfigFlags_NoMouseCursorChange;

    switch (g.renderer_type) {
        .d3d11 => {
            var d3d11: d3d.D3D11 = .init(try d3d.D3D11.VerifiedParam.init(g.param.native));
            g.hwnd = (try d3d11.getHwnd()) orelse return error.GetHwndFailed;
            if (!imgui_c.ImGui_ImplWin32_Init(g.hwnd)) return error.ImGuiW32InitFailed;
            try d3d11_imgui_render.init(d3d11);
        },
        .d3d12 => {
            var d3d12: d3d.D3D12 = .init(try d3d.D3D12.VerifiedParam.init(g.param.native));
            g.hwnd = (try d3d12.getHwnd()) orelse return error.GetHwndFailed;
            if (!imgui_c.ImGui_ImplWin32_Init(g.hwnd)) return error.ImGuiW32InitFailed;
            try d3d12_imgui_render.init(d3d12);
        },
        else => return,
    }

    imgui_initialized = true;
}

const ui_state = struct {
    var show_ui: bool = true;
    var focused_any: bool = false;
};

fn drawUI() void {
    if (!ui_state.show_ui) {
        return;
    }
    _ = cimgui.igBegin("RE ImGui with custom renderer!", &ui_state.show_ui, 0);

    cimgui.igText("This is a basic demostration of a REFramework plugin written in Zig.");
    cimgui.igText("This example uses a custom ImGui renderer, we initialize ImGui ourselves and render in the onPresent callback.");
    cimgui.igText("Current Renderer Backend: %s", @as([*:0]const u8, switch (g.renderer_type) {
        .d3d11 => "D3D11",
        .d3d12 => "D3D12",
        else => "Unknown",
    }));

    _ = cimgui.igEnd();

    ui_state.focused_any = cimgui.igIsWindowFocused(cimgui.ImGuiFocusedFlags_AnyWindow);
}

fn onNewFrame() !void {
    // only draw UI when the main Plugin Menu is being drawn.
    if (!g.api.isDrawingUI()) {
        return;
    }

    try initImGui();

    if (!imgui_initialized) {
        return;
    }

    if (g.renderer_type == .d3d11) {
        imgui_c.ImGui_ImplDX11_NewFrame();
        imgui_c.ImGui_ImplWin32_NewFrame();

        cimgui.igNewFrame();

        drawUI();

        cimgui.igEndFrame();
        cimgui.igRender();

        try d3d11_imgui_render.render();
    } else if (g.renderer_type == .d3d12) {
        imgui_c.ImGui_ImplDX12_NewFrame();
        imgui_c.ImGui_ImplWin32_NewFrame();

        cimgui.igNewFrame();

        drawUI();

        cimgui.igEndFrame();
        cimgui.igRender();

        try d3d12_imgui_render.render();
    }
}

fn onPresent() void {
    onNewFrame() catch |e| {
        log.err("Error newFrame: {}", .{e});
    };
}

extern "c" fn ImGui_ImplWin32_WndProcHandler(
    hWnd: windows.HWND,
    msg: windows.UINT,
    wParam: win32.foundation.WPARAM,
    lParam: windows.LPARAM,
) callconv(.c) win32.foundation.LRESULT;

fn onMessage(hwnd: windows.HWND, msg: windows.UINT, wparam: win32.foundation.WPARAM, lparam: windows.LPARAM) bool {
    if (!imgui_initialized) {
        return true;
    }
    const wmsg = win32.ui.windows_and_messaging;
    const ui_input = win32.ui.input;

    const is_mouse_moving: bool = blk: {
        if (msg == wmsg.WM_INPUT) {
            const raw_input_header_sz: u32 = @truncate(@sizeOf(ui_input.RAWINPUTHEADER));
            var size: u32 = @truncate(@sizeOf(win32.ui.input.RAWINPUT));
            var raw: ui_input.RAWINPUT = std.mem.zeroes(ui_input.RAWINPUT);

            // obtain size?
            const lparam_s: usize = @intCast(lparam);
            _ = ui_input.GetRawInputData(@ptrFromInt(lparam_s), ui_input.RID_INPUT, null, &size, raw_input_header_sz);
            _ = ui_input.GetRawInputData(@ptrFromInt(lparam_s), ui_input.RID_INPUT, @ptrCast(&raw), &size, raw_input_header_sz);

            if (raw.header.dwType == @intFromEnum(ui_input.RIM_TYPEMOUSE)) {
                break :blk raw.data.mouse.lLastX > 0 or raw.data.mouse.lLastY > 0;
            }
        }

        break :blk false;
    };

    _ = ImGui_ImplWin32_WndProcHandler(hwnd, msg, wparam, lparam);

    if (ui_state.show_ui) {
        const io = cimgui.igGetIO();

        if (msg == wmsg.WM_INPUT and wparam & 0xff == wmsg.RIM_INPUTSINK) {
            return false;
        }

        // https://github.com/praydog/REFramework/blob/0a74333ac76774884724bbac2ad7fefba702b6a3/src/REFramework.cpp#L1329

        const forcefully_allowed_messages = [_]windows.UINT{
            wmsg.WM_DEVICECHANGE,
            wmsg.WM_SHOWWINDOW,
            wmsg.WM_ACTIVATE,
            wmsg.WM_ACTIVATEAPP,
            wmsg.WM_CLOSE,
            wmsg.WM_DPICHANGED,
            wmsg.WM_SIZING,
            wmsg.WM_MOUSEACTIVATE,
        };

        if (std.mem.findScalar(windows.UINT, &forcefully_allowed_messages, msg) == null) {
            if (ui_state.focused_any) {
                if (io.*.WantCaptureMouse or io.*.WantCaptureKeyboard or io.*.WantTextInput) {
                    return false;
                }
            } else {
                if (!is_mouse_moving and (io.*.WantCaptureMouse or io.*.WantCaptureKeyboard or io.*.WantTextInput)) {
                    return false;
                }
            }
        }
    }

    return true;
}

fn onDeviceReset() void {
    log.info("Device reset detected, shutting down ImGui", .{});

    imgui_initialized = false;
    switch (g.renderer_type) {
        .d3d11 => {
            imgui_c.ImGui_ImplDX11_Shutdown();
            d3d11_imgui_render.deinit();
        },
        .d3d12 => {
            imgui_c.ImGui_ImplDX12_Shutdown();
            d3d12_imgui_render.deinit();
        },
        else => {},
    }

    g.reset();
}

comptime {
    re.initPlugin(init, .{
        .onPresent = onPresent,
        .onDeviceReset = onDeviceReset,
        .onMessage = onMessage,
    });
}

pub export fn DllMain(
    hinstDLL: windows.HINSTANCE,
    fdwReason: windows.DWORD,
    lpReserved: windows.LPVOID,
) callconv(.winapi) windows.BOOL {
    _ = hinstDLL;
    _ = lpReserved;

    switch (fdwReason) {
        win32.system.system_services.DLL_PROCESS_ATTACH => {
            g.attach();
            d3d11_imgui_render.g.io = g.io;
            d3d12_imgui_render.g.io = g.io;
        },
        win32.system.system_services.DLL_PROCESS_DETACH => {},
        else => {},
    }

    return .TRUE;
}
