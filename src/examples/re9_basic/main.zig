const std = @import("std");

const re = @import("reframework");

const win32 = @import("win32");
const cimgui = @import("cimgui");

const managed_types = @import("managed_types.zig");

const windows = std.os.windows;

const interop = re.interop;

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

        initialized = true;
    }
};

fn drawUI() void {
    cimgui_dll.igSetNextItemOpen(false, cimgui.ImGuiCond_FirstUseEver);
    if (!cimgui_dll.igCollapsingHeader_BoolPtr("RE9 Basic in Zig", null, 0)) {
        return;
    }

    cimgui_dll.igText("This is a basic REFramework plugin example written in Zig!");

    cimgui_dll.igSeparatorText("Basic Hacks");

    _ = cimgui_dll.igCheckbox("Invincibility", &current_hack_state.invincible);
    _ = cimgui_dll.igCheckbox("Infinite Gun Ammo", &current_hack_state.infinite_gun);
    _ = cimgui_dll.igCheckbox("Infinite Axe Durability", &current_hack_state.infinite_axe);
    _ = cimgui_dll.igCheckbox("Infinite Rocket Ammo", &current_hack_state.infinite_rocket);
    _ = cimgui_dll.igCheckbox("No Ammo Consumption", &current_hack_state.no_ammo_consumption);
}

fn onNewFrame() !void {
    {
        g_state.api.lockLua();
        defer g_state.api.unlockLua();
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

fn onDeviceReset() void {
    std.log.info("Device reset detected, clearing interop cache", .{});

    g_state.interop_cache.deinit();
    threaded.deinit();
    _ = debug_allocator.detectLeaks();
    _ = debug_allocator.deinit();
}

comptime {
    re.initPlugin(init, .{
        .requiredVersion = .{
            .gameName = "RE9",
        },
        .onPresent = onPresent,
        .onDeviceReset = onDeviceReset,
        .onImGuiDrawUI = struct {
            fn func(data: *re.API_C.REFImGuiFrameCbData) void {
                @setRuntimeSafety(false);

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

                drawUI();
            }
        }.func,
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
        },
        win32.system.system_services.DLL_PROCESS_DETACH => {},
        else => {},
    }

    return .TRUE;
}
