const std = @import("std");
const windows = std.os.windows;

const re = @import("reframework");
const interop = re.interop;
const d3d = re.d3d;
const d3d12_imgui_render = @import("d3d12_imgui_render.zig");

const win32 = @import("win32");
const cimgui = @import("cimgui");
const imgui_c = @import("imgui_c");

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

const PlayerEquipment = interop.ManagedObject("app.PlayerEquipment", .{
    .consumeLoading = .{
        .params = .{
            .{ .type_name = "System.Int32", .type = i32 },
        },
    },
}, .{});

const HitPoint = interop.ManagedObject("app.HitPoint", .{
    .set_Invincible = .{
        .params = .{
            .{ .type_name = "System.Boolean", .type = bool },
        },
    },
    .get_CurrentMaximumHitPoint = .{
        .params = .{},
        .ret = .{ .type = i32 },
    },
    .get_CurrentHitPoint = .{
        .params = .{},
        .ret = .{ .type = i32 },
    },
    .resetHitPoint = .{
        .params = .{
            .{ .type_name = "System.Int32", .type = i32 },
        },
    },
}, .{});

const PlayerContext = interop.ManagedObject("app.PlayerContext", .{
    .get_HitPoint = .{
        .params = .{},
        .ret = .{ .type = HitPoint },
    },
}, .{});

const CharacterManager = interop.ManagedObject("app.CharacterManager", .{
    .getPlayerContextRef = .{
        .params = .{},
        .ret = .{ .type = ?PlayerContext },
    },
}, .{});

const ItemManager = interop.ManagedObject("app.ItemManager", .{}, .{
    ._InfinityGun = .{ .type = bool },
    ._InfinityAxe = .{ .type = bool },
    ._InfinityRocketLauncher = .{ .type = bool },
});

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
var d3d11: d3d.D3D11 = undefined;
var d3d12: d3d.D3D12 = undefined;

export fn print_win_error_code(msg: [*:0]const u8, res: win32.foundation.HRESULT) callconv(.c) void {
    @setRuntimeSafety(false);
    std.log.err("{s}: 0x{x}", .{ msg, @as(u32, @intCast(res)) });
}

fn initImGui() !void {
    if (imgui_initialized) return;
    if (cimgui.igCreateContext(null) == null) return error.ImGuiCreateContextFailed;
    cimgui.igGetIO().*.IniFilename = "re9_basic.ini".ptr;
    const param = try g_state.api.verifiedParam(.{ .renderer_data = .{.renderer_type} });

    g_state.renderer_type = .fromU32(@intCast(param.safe().renderer_data.safe().renderer_type));

    switch (g_state.renderer_type) {
        .d3d11 => {
            d3d11 = .init(try d3d.D3D11.VerifiedParam.init(param.native));
            g_state.hwnd = (try d3d11.getHwnd()) orelse return error.GetHwndFailed;
            if (!imgui_c.ImGui_ImplWin32_Init(g_state.hwnd)) return error.ImGuiW32InitFailed;
        },
        .d3d12 => {
            const d3d12_param = try d3d.D3D12.VerifiedParam.init(param.native);
            d3d12 = .init(d3d12_param);
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
        d3d12_imgui_render.updateNative(try d3d.D3D12.VerifiedParam.init(g_state.api.param.native));

        // imgui_c.ImGui_ImplDX12_NewFrame();
        // imgui_c.ImGui_ImplWin32_NewFrame();

        // cimgui.igNewFrame();

        // if (show_demo_window) {
        //     cimgui.igShowDemoWindow(&show_demo_window);
        // }

        // cimgui.igEndFrame();
        // cimgui.igRender();

        // try d3d12_imgui_render.renderImGui();
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
    _ = ImGui_ImplWin32_WndProcHandler(hwnd, msg, wparam, lparam);

    return !cimgui.igGetIO().*.WantCaptureMouse and !cimgui.igGetIO().*.WantCaptureKeyboard;
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

const DLL_PROCESS_DETACH: windows.DWORD = 0;
const DLL_PROCESS_ATTACH: windows.DWORD = 1;

pub fn DllMain(
    hinstDLL: windows.HINSTANCE,
    fdwReason: windows.DWORD,
    lpReserved: windows.LPVOID,
) callconv(.winapi) windows.BOOL {
    _ = hinstDLL;
    _ = lpReserved;

    switch (fdwReason) {
        DLL_PROCESS_ATTACH => {
            g_state.allocator = debug_allocator.allocator();
            threaded = .init(g_state.allocator, .{});
            g_state.io = threaded.io();
            g_state.interop_cache = .init(g_state.allocator, g_state.io);
        },
        DLL_PROCESS_DETACH => {},
        else => {},
    }

    return .TRUE;
}
