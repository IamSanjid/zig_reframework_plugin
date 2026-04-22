/// 1-to-1: https://github.com/praydog/REFramework/blob/0a74333ac76774884724bbac2ad7fefba702b6a3/src/REFramework.cpp#L965
const std = @import("std");
const d3d = @import("reframework").d3d;
const win32 = @import("win32");
const cimgui = @import("cimgui");
const imgui_c = @import("imgui_c");

const d3d12 = win32.graphics.direct3d12;
const dxgi = win32.graphics.dxgi;
const windows_programming = win32.system.windows_programming;
const windows = std.os.windows;

const FAILED = win32.zig.FAILED;
const SUCCEEDED = win32.zig.SUCCEEDED;
const FALSE = win32.zig.FALSE;

const RTV = enum(u32) {
    backbuffer_0 = 0,
    backbuffer_1,
    backbuffer_2,
    backbuffer_3,
    backbuffer_4,
    backbuffer_5,
    backbuffer_6,
    backbuffer_7,
    backbuffer_8,
    imgui,
    blank,
    count,

    const backbuffer_last = RTV.backbuffer_8;
};

const SRV = enum(u32) {
    imgui_font_backbuffer,
    imgui_font_vr,
    imgui_vr,
    blank,
    count,
};

const CommandContext = struct {
    cmd_allocator: *d3d12.ID3D12CommandAllocator,
    cmd_list: *d3d12.ID3D12GraphicsCommandList,
    fence: *d3d12.ID3D12Fence,
    fence_value: u64 = 0,
    fence_event: win32.foundation.HANDLE,
    waiting_for_fence: bool = false,
    has_commands: bool = false,

    const Self = @This();

    fn init(device: *d3d12.ID3D12Device, name: [:0]const u16) !Self {
        var instance: Self = .{
            .cmd_allocator = undefined,
            .cmd_list = undefined,
            .fence = undefined,
            .fence_event = undefined,
        };

        if (FAILED(device.CreateCommandAllocator(
            .DIRECT,
            d3d12.IID_ID3D12CommandAllocator,
            @ptrCast(&instance.cmd_allocator),
        ))) {
            return error.CreateCommandAllocatorFailed;
        }
        if (FAILED(device.CreateCommandList(
            0,
            .DIRECT,
            instance.cmd_allocator,
            null, // pipeline state
            d3d12.IID_ID3D12GraphicsCommandList,
            @ptrCast(&instance.cmd_list),
        ))) {
            return error.CreateCommandListFailed;
        }

        _ = instance.cmd_list.ID3D12Object.SetName(name.ptr);

        if (FAILED(device.CreateFence(
            0,
            d3d12.D3D12_FENCE_FLAG_NONE,
            d3d12.IID_ID3D12Fence,
            @ptrCast(&instance.fence),
        ))) {
            return error.CreateFenceFailed;
        }

        _ = instance.fence.ID3D12Object.SetName(name.ptr);
        instance.fence_event = win32.system.threading.CreateEventW(null, FALSE, FALSE, null) orelse return error.CreateEventFailed;

        return instance;
    }

    pub fn deinit(self: *Self) void {
        self.wait(2000);
        _ = self.cmd_list.IUnknown.Release();
        _ = self.cmd_allocator.IUnknown.Release();
        _ = self.fence.IUnknown.Release();
        _ = win32.foundation.CloseHandle(self.fence_event);

        self.* = undefined;
    }

    pub fn wait(self: *Self, ms: u32) void {
        if (self.waiting_for_fence) {
            _ = win32.system.threading.WaitForSingleObject(self.fence_event, ms);
            _ = win32.system.threading.ResetEvent(self.fence_event);
            self.waiting_for_fence = false;
            if (FAILED(self.cmd_allocator.Reset())) {
                log.err("Failed to reset command allocator.", .{});
                return;
            }
            if (FAILED(self.cmd_list.Reset(self.cmd_allocator, null))) {
                log.err("Failed to reset command list.", .{});
                return;
            }
            self.has_commands = false;
        }
    }

    pub fn execute(self: *Self, command_queue: *d3d12.ID3D12CommandQueue) !void {
        if (!self.has_commands) return;

        if (FAILED(self.cmd_list.Close())) {
            return error.CloseCommandListFailed;
        }

        var cmd_lists: [1]*d3d12.ID3D12CommandList = undefined;
        cmd_lists[0] = @ptrCast(self.cmd_list);
        command_queue.ExecuteCommandLists(1, @ptrCast(&cmd_lists[0]));

        self.fence_value += 1;
        _ = command_queue.Signal(self.fence, self.fence_value);
        _ = self.fence.SetEventOnCompletion(self.fence_value, self.fence_event);

        self.waiting_for_fence = true;
        self.has_commands = false;
    }
};

pub const g_state = struct {
    // TODO: Do we really need mutex? Don't know if on_present will be called from different threads...?
    pub var io: ?std.Io = null;
    pub var mtx: std.Io.Mutex = .init;
};

const state = struct {
    var initialized = false;
    var native: d3d.D3D12 = undefined;
    var cmd_ctxs: [@intFromEnum(RTV.backbuffer_last)]CommandContext = undefined;
    var cmd_ctx_index: usize = 0;
    var rtv_desc_heap: *d3d12.ID3D12DescriptorHeap = undefined;
    var srv_desc_heap: *d3d12.ID3D12DescriptorHeap = undefined;
    var rts: [@intFromEnum(RTV.count)]?*d3d12.ID3D12Resource = undefined;
    var rt_width: u32 = 0;
    var rt_height: u32 = 0;
};

const log = std.log.scoped(.d3d12_renderer);

pub fn init(d3d12_ins: d3d.D3D12) !void {
    try g_state.mtx.lock(g_state.io.?);
    defer g_state.mtx.unlock(g_state.io.?);

    if (state.initialized) return;

    state.native = d3d12_ins;

    const device = state.native.device;

    for (&state.cmd_ctxs) |*cmd_ctx| {
        cmd_ctx.* = try CommandContext.init(device, std.unicode.utf8ToUtf16LeStringLiteral("Plugin::d3d12_renderer.cmd_ctx"));
    }
    errdefer {
        for (&state.cmd_ctxs) |*cmd_ctx| {
            cmd_ctx.deinit();
        }
    }

    {
        log.info("Creating RTV descriptor heap...", .{});
        var desc: d3d12.D3D12_DESCRIPTOR_HEAP_DESC = std.mem.zeroes(d3d12.D3D12_DESCRIPTOR_HEAP_DESC);
        desc.Type = .RTV;
        desc.NumDescriptors = @intFromEnum(RTV.count);
        desc.Flags = .{};
        desc.NodeMask = 1;

        if (FAILED(device.CreateDescriptorHeap(&desc, d3d12.IID_ID3D12DescriptorHeap, @ptrCast(&state.rtv_desc_heap)))) {
            return error.CreateRTVDescriptorHeapFailed;
        }

        _ = state.rtv_desc_heap.ID3D12Object.SetName(std.unicode.utf8ToUtf16LeStringLiteral("Plugin::d3d12_renderer.rtv_desc_heap"));
    }
    errdefer _ = state.rtv_desc_heap.IUnknown.Release();

    {
        log.info("Creating SRV descriptor heap...", .{});
        var desc: d3d12.D3D12_DESCRIPTOR_HEAP_DESC = std.mem.zeroes(d3d12.D3D12_DESCRIPTOR_HEAP_DESC);
        desc.Type = .CBV_SRV_UAV;
        desc.NumDescriptors = @intFromEnum(SRV.count);
        desc.Flags = .{ .SHADER_VISIBLE = 1 };

        if (FAILED(device.CreateDescriptorHeap(&desc, d3d12.IID_ID3D12DescriptorHeap, @ptrCast(&state.srv_desc_heap)))) {
            return error.CreateSRVDescriptorHeapFailed;
        }

        _ = state.srv_desc_heap.ID3D12Object.SetName(std.unicode.utf8ToUtf16LeStringLiteral("Plugin::d3d12_renderer.srv_desc_heap"));
    }
    errdefer _ = state.srv_desc_heap.IUnknown.Release();

    log.info("Creating render targets...", .{});

    const swapchain = state.native.swapchain;

    var swapchain_desc: dxgi.DXGI_SWAP_CHAIN_DESC = std.mem.zeroes(dxgi.DXGI_SWAP_CHAIN_DESC);
    if (FAILED(swapchain.IDXGISwapChain.GetDesc(&swapchain_desc))) {
        return error.GetSwapChainDescFailed;
    }

    log.info("Swapchain buffer count: {d}", .{swapchain_desc.BufferCount});

    errdefer {
        for (state.rts) |rt| {
            if (rt) |r| _ = r.IUnknown.Release();
        }
    }

    {
        // Create back buffer rtvs.
        if (swapchain_desc.BufferCount > @intFromEnum(RTV.backbuffer_last) + 1) {
            log.warn("Too many back buffers ({} vs {})", .{ swapchain_desc.BufferCount, @intFromEnum(RTV.backbuffer_last) + 1 });
        }

        for (0..swapchain_desc.BufferCount) |i| {
            if (SUCCEEDED(swapchain.IDXGISwapChain.GetBuffer(@truncate(i), d3d12.IID_ID3D12Resource, @ptrCast(&state.rts[i])))) {
                device.CreateRenderTargetView(state.rts[i], null, getCpuRtv(device, @enumFromInt(i)));
            } else {
                log.err("Failed to get back buffer for rtv {}", .{i});
            }
        }

        const backbuffer = &state.rts[@intFromEnum(RTV.backbuffer_0)];
        if (backbuffer.* == null) {
            // TODO: deinit previously created resources
            return error.GetFirstBackBufferFailed;
        }

        const desc = backbuffer.*.?.GetDesc();

        log.info("Back buffer format: {}", .{desc.Format});

        var props: d3d12.D3D12_HEAP_PROPERTIES = std.mem.zeroes(d3d12.D3D12_HEAP_PROPERTIES);
        props.Type = .DEFAULT;
        props.CPUPageProperty = .UNKNOWN;
        props.MemoryPoolPreference = .UNKNOWN;

        var d3d12_rt_desc = desc;
        d3d12_rt_desc.Format = .R8G8B8A8_UNORM; // for imgui rendering

        var clear_value: d3d12.D3D12_CLEAR_VALUE = std.mem.zeroes(d3d12.D3D12_CLEAR_VALUE);
        clear_value.Format = d3d12_rt_desc.Format;

        if (FAILED(device.CreateCommittedResource(
            &props,
            .{},
            &d3d12_rt_desc,
            .{ .PIXEL_SHADER_RESOURCE = 1 },
            &clear_value,
            d3d12.IID_ID3D12Resource,
            @ptrCast(&state.rts[@intFromEnum(RTV.imgui)]),
        ))) {
            return error.CreateImGuiRenderTargetFailed;
        }

        if (FAILED(device.CreateCommittedResource(
            &props,
            .{},
            &d3d12_rt_desc,
            .{ .PIXEL_SHADER_RESOURCE = 1 },
            &clear_value,
            d3d12.IID_ID3D12Resource,
            @ptrCast(&state.rts[@intFromEnum(RTV.blank)]),
        ))) {
            return error.CreateBlankRenderTargetFailed;
        }

        _ = state.rts[@intFromEnum(RTV.blank)].?.ID3D12Object.SetName(std.unicode.utf8ToUtf16LeStringLiteral("Plugin::d3d12_renderer.rts[BLANK]"));

        device.CreateRenderTargetView(state.rts[@intFromEnum(RTV.imgui)].?, null, getCpuRtv(device, .imgui));
        device.CreateRenderTargetView(state.rts[@intFromEnum(RTV.blank)].?, null, getCpuRtv(device, .blank));
        device.CreateShaderResourceView(state.rts[@intFromEnum(RTV.imgui)].?, null, getCpuSrv(device, .imgui_vr));
        device.CreateShaderResourceView(state.rts[@intFromEnum(RTV.blank)].?, null, getCpuSrv(device, .blank));

        state.rt_height = desc.Height;
        state.rt_width = @truncate(desc.Width);
    }

    log.info("Initializing ImGui...", .{});

    const bb = state.rts[@intFromEnum(RTV.backbuffer_0)].?;
    const bb_desc = bb.GetDesc();

    var init_info: imgui_c.ImGui_ImplDX12_InitInfo = std.mem.zeroes(imgui_c.ImGui_ImplDX12_InitInfo);
    init_info.Device = @ptrCast(device);
    init_info.CommandQueue = @ptrCast(state.native.queue);
    init_info.NumFramesInFlight = @intCast(swapchain_desc.BufferCount);
    init_info.RTVFormat = @intFromEnum(bb_desc.Format);
    init_info.DSVFormat = @intFromEnum(dxgi.common.DXGI_FORMAT_UNKNOWN);
    init_info.SrvDescriptorHeap = @ptrCast(state.srv_desc_heap);
    init_info.LegacySingleSrvCpuDescriptor = .{ .ptr = getCpuSrv(device, .imgui_font_backbuffer).ptr };
    init_info.LegacySingleSrvGpuDescriptor = .{ .ptr = getGpuSrv(device, .imgui_font_backbuffer).ptr };

    if (!imgui_c.ImGui_ImplDX12_Init(&init_info)) {
        return error.ImGuiD3D12InitFailed;
    }

    log.info("Plugin D3D12 for ImGui Initialized!", .{});

    state.initialized = true;
}

pub fn deinit() void {
    g_state.mtx.lockUncancelable(g_state.io.?);
    defer g_state.mtx.unlock(g_state.io.?);

    if (!state.initialized) return;

    state.cmd_ctx_index = 0;
    for (&state.cmd_ctxs) |*cmd_ctx| {
        cmd_ctx.deinit();
    }

    _ = state.rtv_desc_heap.IUnknown.Release();
    _ = state.srv_desc_heap.IUnknown.Release();

    for (state.rts) |rt| {
        if (rt) |r| _ = r.IUnknown.Release();
    }

    state.rt_width = 0;
    state.rt_height = 0;
    state.native = undefined;

    state.initialized = false;
}

pub fn render() !void {
    try g_state.mtx.lock(g_state.io.?);
    defer g_state.mtx.unlock(g_state.io.?);

    if (!state.initialized) return;

    const cmd_ctx = &state.cmd_ctxs[state.cmd_ctx_index];

    const device = state.native.device;
    const swapchain = state.native.swapchain;
    const bb_index = swapchain.GetCurrentBackBufferIndex();

    if (bb_index > state.rts.len or state.rts[bb_index] == null) {
        log.err("RTV for index {} is null or missing, reinitializing...", .{bb_index});
        return error.BackBufferRTVNull;
    }

    cmd_ctx.wait(windows_programming.INFINITE);
    {
        cmd_ctx.has_commands = true;

        var barriers: [1]d3d12.D3D12_RESOURCE_BARRIER = .{std.mem.zeroes(d3d12.D3D12_RESOURCE_BARRIER)};
        barriers[0].Type = .TRANSITION;
        barriers[0].Flags = .{};
        barriers[0].Anonymous.Transition.Subresource = d3d12.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;

        var rts: [1]d3d12.D3D12_CPU_DESCRIPTOR_HANDLE = undefined;

        // Draw to the back buffer.
        barriers[0].Anonymous.Transition.pResource = state.rts[bb_index];
        barriers[0].Anonymous.Transition.StateBefore = d3d12.D3D12_RESOURCE_STATE_PRESENT;
        barriers[0].Anonymous.Transition.StateAfter = d3d12.D3D12_RESOURCE_STATE_RENDER_TARGET;
        cmd_ctx.cmd_list.ResourceBarrier(barriers.len, &barriers);
        rts[0] = getCpuRtv(device, @enumFromInt(bb_index));
        cmd_ctx.cmd_list.OMSetRenderTargets(1, @ptrCast(&rts[0]), 0, null);
        cmd_ctx.cmd_list.SetDescriptorHeaps(1, @ptrCast(&state.srv_desc_heap));

        imgui_c.ImGui_ImplDX12_RenderDrawData(@ptrCast(cimgui.igGetDrawData()), @ptrCast(cmd_ctx.cmd_list));

        barriers[0].Anonymous.Transition.StateBefore = d3d12.D3D12_RESOURCE_STATE_RENDER_TARGET;
        barriers[0].Anonymous.Transition.StateAfter = d3d12.D3D12_RESOURCE_STATE_PRESENT;
        cmd_ctx.cmd_list.ResourceBarrier(barriers.len, &barriers);
    }
    try cmd_ctx.execute(state.native.queue);
}

fn getCpuRtv(device: *d3d12.ID3D12Device, rtv: RTV) d3d12.D3D12_CPU_DESCRIPTOR_HANDLE {
    const base = state.rtv_desc_heap.GetCPUDescriptorHandleForHeapStart();
    const increment = device.GetDescriptorHandleIncrementSize(.RTV);
    return .{ .ptr = base.ptr + @as(u64, @intCast(@intFromEnum(rtv))) * @as(u64, @intCast(increment)) };
}

fn getCpuSrv(device: *d3d12.ID3D12Device, srv: SRV) d3d12.D3D12_CPU_DESCRIPTOR_HANDLE {
    const base = state.srv_desc_heap.GetCPUDescriptorHandleForHeapStart();
    const increment = device.GetDescriptorHandleIncrementSize(.CBV_SRV_UAV);
    return .{ .ptr = base.ptr + @as(u64, @intCast(@intFromEnum(srv))) * @as(u64, @intCast(increment)) };
}

fn getGpuSrv(device: *d3d12.ID3D12Device, srv: SRV) d3d12.D3D12_GPU_DESCRIPTOR_HANDLE {
    const base = state.srv_desc_heap.GetGPUDescriptorHandleForHeapStart();
    const increment = device.GetDescriptorHandleIncrementSize(.CBV_SRV_UAV);
    return .{ .ptr = base.ptr + @as(u64, @intCast(@intFromEnum(srv))) * @as(u64, @intCast(increment)) };
}

test {
    @import("std").testing.refAllDecls(@This());
}
