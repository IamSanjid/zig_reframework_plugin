const std = @import("std");

const re = @import("reframework");

const win32 = @import("win32");
const cimgui = @import("cimgui");
const imgui_c = @import("imgui_c");

const d3d12_imgui_render = @import("d3d12_imgui_render.zig");
const d3d11_imgui_render = @import("d3d11_imgui_render.zig");

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
                if (current_hack_state.no_ammo_consumption) {
                    return .skip_original;
                }
                return .call_original;
            }
        }.func,
        null,
        false,
    );
    std.log.info("Hooked app.PlayerEquipment.consumeLoading id: {d}", .{consume_loading_hook});
}

// var hacked_hp: bool = false;
// var hacked_ammo: bool = false;

const Hack = struct {
    invincible: bool = true,
    infinite_gun: bool = true,
    infinite_axe: bool = true,
    infinite_rocket: bool = true,
    no_ammo_consumption: bool = true,
};

var old_hack_state: ?Hack = null;
var current_hack_state: Hack = .{};

fn applyHPHack() !void {
    if (!current_hack_state.invincible) {
        return;
    }
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

    if (old_hack_state == null) {
        old_hack_state = .{
            .invincible = current_hack_state.invincible,
            .infinite_gun = infinite_gun,
            .infinite_axe = infinite_axe,
            .infinite_rocket = infinite_rocket,
            .no_ammo_consumption = current_hack_state.no_ammo_consumption,
        };
    }

    // restoring old default in-game value.
    if (!current_hack_state.infinite_gun)
        current_hack_state.infinite_gun = old_hack_state.?.infinite_gun;
    if (!current_hack_state.infinite_axe)
        current_hack_state.infinite_axe = old_hack_state.?.infinite_axe;
    if (!current_hack_state.infinite_rocket)
        current_hack_state.infinite_rocket = old_hack_state.?.infinite_rocket;

    if (infinite_gun != current_hack_state.infinite_gun) {
        try item_mgr.set(._InfinityGun, .fo(g_state.sdk), current_hack_state.infinite_gun);
    }

    if (infinite_axe != current_hack_state.infinite_axe) {
        try item_mgr.set(._InfinityAxe, .fo(g_state.sdk), current_hack_state.infinite_axe);
    }

    if (infinite_rocket != current_hack_state.infinite_rocket) {
        try item_mgr.set(._InfinityRocketLauncher, .fo(g_state.sdk), current_hack_state.infinite_rocket);
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

    cimgui.igGetIO().*.IniFilename = "re9_basic.ini";
    cimgui.igGetIO().*.ConfigFlags |= cimgui.ImGuiConfigFlags_NoMouseCursorChange;

    const param = try g_state.api.verifiedParam(.{ .renderer_data = .{.renderer_type} });

    g_state.renderer_type = .fromU32(@intCast(param.safe().renderer_data.safe().renderer_type));

    switch (g_state.renderer_type) {
        .d3d11 => {
            var d3d11: d3d.D3D11 = .init(try d3d.D3D11.VerifiedParam.init(param.native));
            g_state.hwnd = (try d3d11.getHwnd()) orelse return error.GetHwndFailed;
            if (!imgui_c.ImGui_ImplWin32_Init(g_state.hwnd)) return error.ImGuiW32InitFailed;
            try d3d11_imgui_render.init(d3d11);
        },
        .d3d12 => {
            var d3d12: d3d.D3D12 = .init(try d3d.D3D12.VerifiedParam.init(param.native));
            g_state.hwnd = (try d3d12.getHwnd()) orelse return error.GetHwndFailed;
            if (!imgui_c.ImGui_ImplWin32_Init(g_state.hwnd)) return error.ImGuiW32InitFailed;
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
    _ = cimgui.igBegin("RE9 Basic in Zig!", &ui_state.show_ui, 0);

    cimgui.igText("This is a basic REFramework plugin example written in Zig!");

    cimgui.igSeparatorText("Basic Hacks");

    _ = cimgui.igCheckbox("Invincibility", &current_hack_state.invincible);
    _ = cimgui.igCheckbox("Infinite Gun Ammo", &current_hack_state.infinite_gun);
    _ = cimgui.igCheckbox("Infinite Axe Durability", &current_hack_state.infinite_axe);
    _ = cimgui.igCheckbox("Infinite Rocket Ammo", &current_hack_state.infinite_rocket);
    _ = cimgui.igCheckbox("No Ammo Consumption", &current_hack_state.no_ammo_consumption);

    _ = cimgui.igEnd();

    ui_state.focused_any = cimgui.igIsWindowFocused(cimgui.ImGuiFocusedFlags_AnyWindow);
}

fn onNewFrame() !void {
    // only draw UI when the main Plugin Menu is being drawn.
    if (g_state.api.isDrawingUI()) {
        try initImGui();

        if (!imgui_initialized) {
            return;
        }

        if (g_state.renderer_type == .d3d11) {
            imgui_c.ImGui_ImplDX11_NewFrame();
            imgui_c.ImGui_ImplWin32_NewFrame();

            cimgui.igNewFrame();

            drawUI();

            cimgui.igEndFrame();
            cimgui.igRender();

            try d3d11_imgui_render.render();
        } else if (g_state.renderer_type == .d3d12) {
            imgui_c.ImGui_ImplDX12_NewFrame();
            imgui_c.ImGui_ImplWin32_NewFrame();

            cimgui.igNewFrame();

            drawUI();

            cimgui.igEndFrame();
            cimgui.igRender();

            try d3d12_imgui_render.render();
        }
    }

    {
        try g_state.api.lockLua(g_state.io);
        defer g_state.api.unlockLua(g_state.io);
        try applyHPHack();
        try applyInfiniteAmmoHack();
    }
}

fn onPresent() void {
    onNewFrame() catch |e| {
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
    std.log.info("Device reset detected, clearing interop cache", .{});

    imgui_initialized = false;
    switch (g_state.renderer_type) {
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

            d3d11_imgui_render.g_state.io = g_state.io;
            d3d12_imgui_render.g_state.io = g_state.io;
        },
        win32.system.system_services.DLL_PROCESS_DETACH => {},
        else => {},
    }

    return .TRUE;
}
