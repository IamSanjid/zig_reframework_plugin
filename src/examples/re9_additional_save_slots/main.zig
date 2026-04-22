const std = @import("std");
const re = @import("reframework");

const windows = std.os.windows;

const interop = re.interop;

const max_save_games = 90;

const State = struct {
    api: re.api.Api,
    sdk: re.api.VerifiedSdk(sdk_spec),
    allocator: std.mem.Allocator,
    io: std.Io,
    interop_cache: interop.Cache,
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

fn init(api: re.Api) !void {
    g_state.api = api;

    std.log.info(
        "RE9 Save Slot increase in Zig! Required REFramework Version: {}.{}.{}",
        .{
            re.PluginVersion.default.major,
            re.PluginVersion.default.minor,
            re.PluginVersion.default.patch,
        },
    );

    g_state.sdk = try g_state.api.verifiedSdk(sdk_spec);
}

var initialized = false;

const SaveSlotSegmentType = enum(c_int) {
    invalid = 0,
    default_0 = 1,
};

fn newFrame() !void {
    // TODO: Implement it? https://github.com/praydog/RE9AdditionalSaveSlots/blob/87c18cb40ff672e1cc9107e10cd380a10acc07ec/reframework/plugins/source/AdditionalSaves.cs#L1
    if (initialized) {
        return;
    }

    try g_state.api.lockLua(g_state.io);
    defer g_state.api.unlockLua(g_state.io);

    const save_mgr = re.api.sdk.getManagedSingleton(.fo(g_state.sdk), "app.SaveServiceManager") orelse return;
    var partitions_dict = try g_state.interop_cache.getField(
        .fo(g_state.sdk),
        save_mgr,
        re.api.sdk.ManagedObject,
        ._SaveSlotPartitions,
    );
    std.log.info("Before set app.SaveServiceManager._SaveSlotPartitions = 0x{x}", .{@intFromPtr(partitions_dict.raw)});
    try g_state.interop_cache.setField(
        .fo(g_state.sdk),
        save_mgr,
        ._SaveSlotPartitions,
        partitions_dict,
    );
    partitions_dict = try g_state.interop_cache.getField(
        .fo(g_state.sdk),
        save_mgr,
        re.api.sdk.ManagedObject,
        ._SaveSlotPartitions,
    );
    std.log.info("After set app.SaveServiceManager._SaveSlotPartitions = 0x{x}", .{@intFromPtr(partitions_dict.raw)});

    const value_cell = try g_state.interop_cache.callMethod(
        .fo(g_state.sdk),
        partitions_dict,
        "getValue(app.SaveSlotSegmentType)",
        .{},
        .{ .type = ?re.api.sdk.ManagedObject },
        .{SaveSlotSegmentType.default_0},
    );
    if (value_cell) |v| {
        std.log.info("getValue returned = 0x{x}", .{@intFromPtr(v.raw)});
    } else {
        std.log.info("getValue returned = null", .{});
    }

    initialized = true;
}

fn onPresent() void {
    newFrame() catch |e| {
        if (g_state.interop_cache.ownDiagnostics()) |val| {
            std.log.err("Interop error: \n{s}", .{val});
        } else |_| {}
        std.log.err("Error newFrame: {}", .{e});
    };
}

comptime {
    re.initPlugin(init, .{
        .onPresent = onPresent,
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
        DLL_PROCESS_DETACH => {
            threaded.deinit();
            _ = debug_allocator.detectLeaks();
            _ = debug_allocator.deinit();
        },
        else => {},
    }

    return .TRUE;
}
