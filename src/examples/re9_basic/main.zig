const std = @import("std");

const re = @import("reframework");

const win32 = @import("win32");
const cimgui = @import("cimgui");
const imgui_c = @import("imgui_c");

const d3d12_imgui_render = @import("d3d12_imgui_render.zig");

const managed_types = @import("managed_types.zig");

const windows = std.os.windows;

const interop = re.interop;
const d3d = re.d3d;

const State = struct {
    api: re.api.Api,
    sdk: re.api.VerifiedSdk(sdk_spec),
    allocator: std.mem.Allocator,
    io: std.Io,
    interop_cache: interop.Cache,
    hwnd: windows.HWND,
    renderer_type: re.api.RendererType,
};

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
var threaded: std.Io.Threaded = undefined;
var g_state: State = undefined;

pub fn pluginLog(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const log_msg = std.fmt.allocPrintSentinel(
        g_state.allocator,
        (if (scope != .default) ("(" ++ @tagName(scope) ++ "): ") else "") ++ format,
        args,
        0,
    ) catch return;
    defer g_state.allocator.free(log_msg);
    switch (message_level) {
        .err => g_state.api.logError("%s", .{log_msg.ptr}),
        .warn => g_state.api.logWarn("%s", .{log_msg.ptr}),
        else => g_state.api.logInfo("%s", .{log_msg.ptr}),
    }
}

pub const std_options: std.Options = .{
    .logFn = pluginLog,
};

const sdk_spec = .{
    .functions = .{
        .get_managed_singleton,
        .get_tdb,
        .add_hook,
        .remove_hook,
        .create_managed_string_normal,
    },
    .managed_object = .{
        .get_type_definition,
    },
    .method = .{
        .invoke,
        .get_return_type,
        .get_num_params,
        .get_params,
    },
    .field = .{
        .get_data_raw,
        .get_type,
    },
    .tdb = .find_type,
    .type_definition = .all,
};

const PlayerEquipment = managed_types.PlayerEquipment;
const HitPoint = managed_types.HitPoint;
const PlayerContext = managed_types.PlayerContext;
const CharacterManager = managed_types.CharacterManager;
const ItemManager = managed_types.ItemManager;

fn init(api: re.Api) !void {
    g_state.api = api;

    std.log.info(
        "RE9 Basic Hacks in Zig! Required REFramework Version: {}.{}.{}",
        .{
            re.PluginVersion.default.major,
            re.PluginVersion.default.minor,
            re.PluginVersion.default.patch,
        },
    );

    g_state.sdk = try g_state.api.verifiedSdk(sdk_spec);

    const player_equipment_runtime = try PlayerEquipment.Runtime.get(&g_state.interop_cache, .fo(g_state.sdk));
    const consumeLoading = player_equipment_runtime.getMethod(.consumeLoading);
    const consume_loading_hook = consumeLoading.addHook(
        .fromOther(g_state.sdk.safe().functions),
        struct {
            fn func(args: ?[]?*anyopaque, arg_types: ?[]re.api.sdk.TypeDefinition, ret_addr: u64) re.api.HookCall {
                _ = args;
                _ = arg_types;
                _ = ret_addr;
                return .skip_original;
            }
        }.func,
        null,
        false,
    );
    std.log.info("Hooked app.PlayerEquipment.consumeLoading id: {d}", .{consume_loading_hook});
}

// var hacked_hp: bool = false;
// var hacked_ammo: bool = false;

fn applyHPHack() !void {
    const char_mgr = try CharacterManager.init(
        &g_state.interop_cache,
        .fo(g_state.sdk),
        re.api.sdk.getManagedSingleton(.fo(g_state.sdk), "app.CharacterManager") orelse return,
    );
    const player_context = (try char_mgr.call(.getPlayerContextRef, .fo(g_state.sdk), .{})) orelse return;
    const hit_point = try player_context.call(.get_HitPoint, .fo(g_state.sdk), .{});

    try hit_point.call(.set_Invincible, .fo(g_state.sdk), .{true});

    const max_hp = try hit_point.call(.get_CurrentMaximumHitPoint, .fo(g_state.sdk), .{});
    const cur_hp = try hit_point.call(.get_CurrentHitPoint, .fo(g_state.sdk), .{});
    if (max_hp > 0 and cur_hp < max_hp) {
        try hit_point.call(.resetHitPoint, .fo(g_state.sdk), .{max_hp});
    }
    // std.log.info("Hacked Infinite HP! HP: {}/{}", .{ cur_hp, max_hp });
    // hacked_hp = true;
}

fn applyInfiniteAmmoHack() !void {
    const item_mgr = try ItemManager.init(
        &g_state.interop_cache,
        .fo(g_state.sdk),
        re.api.sdk.getManagedSingleton(
            .fo(g_state.sdk),
            "app.ItemManager",
        ) orelse return,
    );

    const infinite_gun = try item_mgr.get(._InfinityGun, .fo(g_state.sdk));
    const infinite_axe = try item_mgr.get(._InfinityAxe, .fo(g_state.sdk));
    const infinite_rocket = try item_mgr.get(._InfinityRocketLauncher, .fo(g_state.sdk));

    if (!infinite_gun) {
        try item_mgr.set(._InfinityGun, .fo(g_state.sdk), true);
    }

    if (!infinite_axe) {
        try item_mgr.set(._InfinityAxe, .fo(g_state.sdk), true);
    }

    if (!infinite_rocket) {
        try item_mgr.set(._InfinityRocketLauncher, .fo(g_state.sdk), true);
    }

    //infinite_gun = try item_mgr.get(._InfinityGun, .fo(g_state.sdk));
    //infinite_axe = try item_mgr.get(._InfinityAxe, .fo(g_state.sdk));
    //infinite_rocket = try item_mgr.get(._InfinityRocketLauncher, .fo(g_state.sdk));
    // hacked_ammo = infinite_gun and infinite_axe and infinite_rocket;
    // if (hacked_ammo) {
    //     std.log.info("Hacked Infinite Ammo!", .{});
    // }
}

var imgui_initialized: bool = false;

export fn print_win_error_code(msg: [*:0]const u8, res: win32.foundation.HRESULT) callconv(.c) void {
    @setRuntimeSafety(false);
    std.log.err("{s}: 0x{x}", .{ msg, @as(u32, @intCast(res)) });
}

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

    cimgui.igGetIO().*.IniFilename = "re9_basic.ini".ptr;
    const param = try g_state.api.verifiedParam(.{ .renderer_data = .{.renderer_type} });

    g_state.renderer_type = .fromU32(@intCast(param.safe().renderer_data.safe().renderer_type));

    switch (g_state.renderer_type) {
        .d3d11 => {
            var d3d11: d3d.D3D11 = .init(try d3d.D3D11.VerifiedParam.init(param.native));
            g_state.hwnd = (try d3d11.getHwnd()) orelse return error.GetHwndFailed;
            if (!imgui_c.ImGui_ImplWin32_Init(g_state.hwnd)) return error.ImGuiW32InitFailed;
        },
        .d3d12 => {
            const d3d12_param = try d3d.D3D12.VerifiedParam.init(param.native);
            var d3d12: d3d.D3D12 = .init(d3d12_param);
            g_state.hwnd = (try d3d12.getHwnd()) orelse return error.GetHwndFailed;
            if (!imgui_c.ImGui_ImplWin32_Init(g_state.hwnd)) return error.ImGuiW32InitFailed;
            try d3d12_imgui_render.init(d3d12_param);
        },
        else => return,
    }

    imgui_initialized = true;
}

var show_demo_window: bool = true;

fn newFrame() !void {
    try initImGui();

    {
        try g_state.api.lockLua(g_state.io);
        defer g_state.api.unlockLua(g_state.io);
        try applyHPHack();
        try applyInfiniteAmmoHack();
    }

    if (!imgui_initialized) {
        return;
    }

    if (g_state.renderer_type == .d3d12) {
        imgui_c.ImGui_ImplDX12_NewFrame();
        imgui_c.ImGui_ImplWin32_NewFrame();

        cimgui.igNewFrame();

        _ = cimgui.igBegin("HelloWorld!", &show_demo_window, 0);
        _ = cimgui.igText("This is a basic REFramework plugin example written in Zig!");
        _ = cimgui.igText("Feel free to use this as a starting point for your own plugins.");
        _ = cimgui.igText("Check out the source code for this example to see how it works.");
        _ = cimgui.igEnd();

        cimgui.igEndFrame();
        cimgui.igRender();

        try d3d12_imgui_render.render();
    }
}

fn onPresent() void {
    newFrame() catch |e| {
        if (g_state.interop_cache.ownDiagnostics()) |val| {
            if (val.len > 0) {
                std.log.err("Interop error: \n{s}", .{val});
            }
        } else |_| {}
        std.log.err("Error newFrame: {}", .{e});
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
    _ = ImGui_ImplWin32_WndProcHandler(hwnd, msg, wparam, lparam);

    // const io = cimgui.igGetIO();
    if (show_demo_window) {
        const wmsg = win32.ui.windows_and_messaging;
        if (msg == wmsg.WM_INPUT and wparam & 0xff == wmsg.RIM_INPUT) {
            return false;
        }

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
        for (forcefully_allowed_messages) |allowed_msg| {
            if (msg != allowed_msg) {
                continue;
            }
            // TODO: ..
            // if (io.*.WantCaptureMouse or io.*.WantCaptureKeyboard or io.*.WantTextInput) {
            //     return false;
            // }
        }
    }

    return true;
}

fn onDeviceReset() void {
    std.log.info("Device reset detected, clearing interop cache", .{});

    imgui_initialized = false;
    switch (g_state.renderer_type) {
        .d3d11 => {
            imgui_c.ImGui_ImplDX11_Shutdown();
        },
        .d3d12 => {
            d3d12_imgui_render.deinit();
        },
        else => {},
    }

    g_state.interop_cache.deinit();
    threaded.deinit();
    _ = debug_allocator.detectLeaks();
    _ = debug_allocator.deinit();
}

comptime {
    re.initPlugin(init, .{
        .onPresent = onPresent,
        .onDeviceReset = onDeviceReset,
        .onMessage = onMessage,
    });
}

pub fn DllMain(
    hinstDLL: windows.HINSTANCE,
    fdwReason: windows.DWORD,
    lpReserved: windows.LPVOID,
) callconv(.winapi) windows.BOOL {
    _ = hinstDLL;
    _ = lpReserved;

    switch (fdwReason) {
        win32.system.system_services.DLL_PROCESS_ATTACH => {
            g_state.allocator = debug_allocator.allocator();
            threaded = .init(g_state.allocator, .{});
            g_state.io = threaded.io();
            g_state.interop_cache = .init(g_state.allocator, g_state.io);

            d3d12_imgui_render.g_state.io = g_state.io;
        },
        win32.system.system_services.DLL_PROCESS_DETACH => {},
        else => {},
    }

    return .TRUE;
}
