const std = @import("std");
const re = @import("reframework");
const cimgui = @import("cimgui");

const cimgui_dll = @import("cimgui_dll.zig");

const windows = std.os.windows;

const interop = re.interop;

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

const log = std.log.scoped(.re_info);

const g = struct {
    var allocator: std.mem.Allocator = undefined;
    var io: std.Io = undefined;
    var interop_cache: interop.ManagedTypeCache = undefined;
    var api: re.Api = undefined;
    var sdk: re.api.VerifiedSdk(re.api.specs.minimal.sdk) = undefined;
    var tdb: re.sdk.Tdb = undefined;

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    var threaded: std.Io.Threaded = undefined;

    fn init(init_api: re.Api) !void {
        api = init_api;
        sdk = try api.verifiedSdk(re.api.specs.minimal.sdk);
        tdb = re.sdk.getTdb(.fo(g.sdk)) orelse return error.TdbNotFound;
    }

    fn attach() void {
        threaded = .init(debug_allocator.allocator(), .{});
        allocator = debug_allocator.allocator();
        io = threaded.io();
        interop_cache = .init(debug_allocator.allocator(), io);
    }

    fn reset() void {
        interop_cache.deinit();

        threaded.deinit();
        _ = debug_allocator.detectLeaks();
        _ = debug_allocator.deinit();
    }
};

fn init(api: re.Api) !void {
    try g.init(api);
}

const u = struct {
    var buf = std.mem.zeroes([256]u8);
    var bufZ = std.mem.zeroes([256:0]u8);
    var type_def_addr_buf = std.mem.zeroes([17:0]u8);
    var managed_obj_addr_buf = std.mem.zeroes([17:0]u8);
    var type_def: ?re.sdk.TypeDefinition = null;
    var managed_obj: ?re.sdk.ManagedObject = null;
    var arena: std.heap.ArenaAllocator = undefined;
};

fn draw(data: *re.API_C.REFImGuiFrameCbData) !void {
    try cimgui_dll.init();

    cimgui_dll.igSetCurrentContext(@ptrCast(@alignCast(data.context)));
    cimgui_dll.igSetAllocatorFunctions(
        @ptrCast(@alignCast(data.malloc_fn)),
        @ptrCast(@alignCast(data.free_fn)),
        data.user_data,
    );

    const arena = u.arena.allocator();
    defer _ = u.arena.reset(.retain_capacity);

    cimgui_dll.igSetNextItemOpen(false, cimgui.ImGuiCond_FirstUseEver);
    if (!cimgui_dll.igCollapsingHeader_BoolPtr("RE Info in Zig", null, 0)) {
        return;
    }

    if (cimgui_dll.igInputText("Managed Obj Addr", &u.managed_obj_addr_buf, u.managed_obj_addr_buf.len, cimgui.ImGuiInputTextFlags_CharsHexadecimal, null, null)) {
        if (u.managed_obj_addr_buf[0] != 0) {
            errdefer u.managed_obj_addr_buf = std.mem.zeroes([17:0]u8);

            const str: []u8 = std.mem.sliceTo(&u.managed_obj_addr_buf, 0);
            const managed_obj_addr = try std.fmt.parseInt(usize, str, 16);
            u.managed_obj = .{ .raw = @ptrFromInt(managed_obj_addr) };
        } else {
            u.managed_obj = null;
        }
    }

    if (cimgui_dll.igInputText("TypeDef Addr", &u.type_def_addr_buf, u.type_def_addr_buf.len, cimgui.ImGuiInputTextFlags_CharsHexadecimal, null, null)) {
        if (u.type_def_addr_buf[0] != 0) {
            errdefer u.type_def_addr_buf = std.mem.zeroes([17:0]u8);

            const str: []u8 = std.mem.sliceTo(&u.type_def_addr_buf, 0);
            const type_def_addr = try std.fmt.parseInt(usize, str, 16);
            u.type_def = .{ .raw = @ptrFromInt(type_def_addr) };
        } else {
            u.type_def = null;
        }
    }

    if (u.managed_obj) |managed_obj| {
        errdefer u.managed_obj = null;

        const type_def = managed_obj.getTypeDefinition(.fo(g.sdk)) orelse return error.TypeDefNotFound;
        const type_name = try type_def.getFullNameAlloc(.fo(g.sdk), arena);
        const type_name_label = try std.fmt.allocPrintSentinel(arena, "Managed Object Type Name: {s}", .{type_name}, 0);
        cimgui_dll.igText(type_name_label);

        cimgui_dll.igText("Managed Object Size: 0x%x", type_def.getSize(.fo(g.sdk)));
    }

    if (u.type_def) |type_def| {
        errdefer u.type_def = null;

        const type_name = try type_def.getFullNameAlloc(.fo(g.sdk), arena);
        const type_name_label = try std.fmt.allocPrintSentinel(arena, "Type Name: {s}", .{type_name}, 0);
        cimgui_dll.igText(type_name_label);

        cimgui_dll.igText("Size: 0x%x", type_def.getSize(.fo(g.sdk)));
    }
}

comptime {
    re.initPlugin(init, .{
        .onImGuiDrawUI = struct {
            fn func(data: *re.API_C.REFImGuiFrameCbData) void {
                draw(data) catch |e| {
                    log.err("Error in draw: {}", .{e});
                };
            }
        }.func,
        .onDeviceReset = struct {
            fn func() void {
                g.reset();
            }
        }.func,
    });
}

const DLL_PROCESS_DETACH: windows.DWORD = 0;
const DLL_PROCESS_ATTACH: windows.DWORD = 1;

pub export fn DllMain(
    hinstDLL: windows.HINSTANCE,
    fdwReason: windows.DWORD,
    lpReserved: windows.LPVOID,
) callconv(.winapi) windows.BOOL {
    _ = hinstDLL;
    _ = lpReserved;

    switch (fdwReason) {
        DLL_PROCESS_ATTACH => {
            g.attach();
            u.arena = .init(g.allocator);
        },
        DLL_PROCESS_DETACH => {
            g.reset();
        },
        else => {},
    }

    return .TRUE;
}
