const std = @import("std");
const windows = std.os.windows;
const re = @import("reframework");
const interop = re.interop;
const d3d_renderer = re.d3d_renderer;

const win32 = @import("win32");
const cimgui = @import("cimgui");
const imgui_c = @import("imgui_c");

const State = struct {
    api: re.api.Api,
    sdk: re.api.VerifiedSdk(sdk_spec),
    allocator: std.mem.Allocator,
    io: std.Io,
    interop_cache: interop.Cache,
    hwnd: ?win32.foundation.HWND,
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
        format ++ if (scope != .default) ("(" ++ @tagName(scope) ++ ")") else "",
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
var d3d11: d3d_renderer.D3D11 = undefined;
var d3d12: d3d_renderer.D3D12 = undefined;

fn initImGui() !void {
    if (imgui_initialized) return;
    _ = cimgui.igDebugCheckVersionAndDataLayout(
        cimgui.igGetVersion(),
        @sizeOf(cimgui.ImGuiIO),
        @sizeOf(cimgui.ImGuiStyle),
        @sizeOf(cimgui.ImVec2),
        @sizeOf(cimgui.ImVec4),
        @sizeOf(cimgui.ImDrawVert),
        @sizeOf(cimgui.ImDrawIdx),
    );
    _ = cimgui.igCreateContext(null);
    cimgui.igGetIO().*.IniFilename = "re9_basic.ini".ptr;
    const param = try g_state.api.verifiedParam(.{ .renderer_data = .{.renderer_type} });
    const renderer_type: re.api.RendererType = .fromU32(@intCast(param.safe().renderer_data.safe().renderer_type));
    std.log.info("Renderer Type: {}", .{renderer_type});
    switch (renderer_type) {
        .d3d11 => {
            d3d11 = .init(try d3d_renderer.D3D11.VerifiedParam.init(param.native));
            g_state.hwnd = try d3d11.getHwnd();
            if (g_state.hwnd) |hwnd| {
                std.log.info("Got HWND: {p}", .{hwnd});
                if (imgui_c.ImGui_ImplWin32_Init(hwnd)) {
                    std.log.info("Initialized ImGui Win32 backend", .{});
                } else {
                    std.log.warn("Failed to initialize ImGui Win32 backend", .{});
                }
            } else {
                std.log.warn("Failed to get HWND from D3D11 swapchain, ImGui Win32 backend will not be initialized", .{});
            }
        },
        .d3d12 => {
            d3d12 = .init(try d3d_renderer.D3D12.VerifiedParam.init(param.native));
            g_state.hwnd = try d3d12.getHwnd();
            if (g_state.hwnd) |hwnd| {
                std.log.info("Got HWND: {p}", .{hwnd});
                if (imgui_c.ImGui_ImplWin32_Init(hwnd)) {
                    std.log.info("Initialized ImGui Win32 backend", .{});
                } else {
                    std.log.warn("Failed to initialize ImGui Win32 backend", .{});
                }
            } else {
                std.log.warn("Failed to get HWND from D3D12 swapchain, ImGui Win32 backend will not be initialized", .{});
            }
        },
        else => return,
    }

    imgui_initialized = true;
}

fn newFrame() !void {
    try initImGui();

    {
        try g_state.api.lockLua(g_state.io);
        defer g_state.api.unlockLua(g_state.io);
        try applyHPHack();
        try applyInfiniteAmmoHack();
    }
}

fn onPresent() void {
    newFrame() catch |e| {
        if (g_state.interop_cache.ownDiagnostics()) |val| {
            std.log.err("Interop error: \n{s}", .{val});
        } else |_| {}
        std.log.err("Error newFrame: {}", .{e});
    };
}

fn onDeviceReset() void {
    std.log.info("Device reset detected, clearing interop cache", .{});
    g_state.interop_cache.deinit();
    threaded.deinit();
    _ = debug_allocator.detectLeaks();
    _ = debug_allocator.deinit();
}

comptime {
    re.initPlugin(init, .{
        .onPresent = onPresent,
        .onDeviceReset = onDeviceReset,
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
