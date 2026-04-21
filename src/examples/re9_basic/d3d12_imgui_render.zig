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

// simple recursive mutex implementation for ImGui rendering
const RecursiveMutex = struct {
    mutex: std.Io.Mutex = .init,
    owner_thread_id: std.Thread.Id = 0,
    recursion_count: usize = 0,

    pub fn lock(self: *RecursiveMutex, io: std.Io) void {
        const current_thread_id = std.Thread.getCurrentId();
        if (self.owner_thread_id == current_thread_id) {
            self.recursion_count += 1;
            return;
        }

        self.mutex.lock(io);
        self.owner_thread_id = current_thread_id;
        self.recursion_count = 1;
    }

    pub fn unlock(self: *RecursiveMutex) void {
        if (self.recursion_count == 0) {
            return; // Not locked, do nothing
        }

        self.recursion_count -= 1;
        if (self.recursion_count == 0) {
            self.owner_thread_id = 0;
            self.mutex.unlock();
        }
    }
};

const CommandContext = struct {
    cmd_allocator: *d3d12.ID3D12CommandAllocator,
    cmd_list: *d3d12.ID3D12GraphicsCommandList,
    fence: *d3d12.ID3D12Fence,
    fence_value: u64 = 0,
    fence_handle: win32.foundation.HANDLE,
    mtx: RecursiveMutex = .{},
    waiting_for_fence: bool = false,
    has_commands: bool = false,

    const Self = @This();

    fn init(device: *d3d12.ID3D12Device, name: ?[:0]const u16) !Self {
        var instance: Self = undefined;

        const name_ptr: ?[*:0]const u16 = if (name) |n| n.ptr else null;

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
            d3d12.IID_ID3D12CommandList,
            @ptrCast(&instance.cmd_list),
        ))) {
            return error.CreateCommandListFailed;
        }

        _ = instance.cmd_list.ID3D12Object.SetName(name_ptr);

        if (FAILED(device.CreateFence(
            0,
            d3d12.D3D12_FENCE_FLAG_NONE,
            d3d12.IID_ID3D12Fence,
            @ptrCast(&instance.fence),
        ))) {
            return error.CreateFenceFailed;
        }

        _ = instance.fence.ID3D12Object.SetName(name_ptr);
        instance.fence_handle = win32.system.threading.CreateEventW(null, FALSE, FALSE, null) orelse return error.CreateEventFailed;

        return instance;
    }
};

const state = struct {
    var initialized = false;
    var native: d3d.D3D12 = undefined;
    var cmd_ctxs: [@intFromEnum(RTV.backbuffer_last)]CommandContext = undefined;
    var rtv_desc_heap: *d3d12.ID3D12DescriptorHeap = undefined;
    var srv_desc_heap: *d3d12.ID3D12DescriptorHeap = undefined;
    var rts: [@intFromEnum(RTV.count)]?*d3d12.ID3D12Resource = undefined;
    var rt_width: u32 = 0;
    var rt_height: u32 = 0;
    var imgui_backend_datas: [2]?*anyopaque = undefined;
};

const log = std.log.scoped(.d3dd12_renderer);

pub fn init(param: d3d.D3D12.VerifiedParam) !void {
    if (state.initialized) return;
    state.native = .init(param);

    const device = state.native.device;

    for (&state.cmd_ctxs) |*cmd_ctx| {
        cmd_ctx.* = try CommandContext.init(device, std.unicode.utf8ToUtf16LeStringLiteral("Plugin::d3d12_renderer.cmd_ctx"));
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

    log.info("Creating render targets...", .{});

    const swapchain = state.native.swapchain;

    var swapchain_desc: dxgi.DXGI_SWAP_CHAIN_DESC = std.mem.zeroes(dxgi.DXGI_SWAP_CHAIN_DESC);
    if (FAILED(swapchain.IDXGISwapChain.GetDesc(&swapchain_desc))) {
        return error.GetSwapChainDescFailed;
    }

    log.info("Swapchain buffer count: {d}", .{swapchain_desc.BufferCount});

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
        return error.ImGuiInitFailed;
    }

    state.imgui_backend_datas[0] = cimgui.igGetIO().*.BackendRendererUserData;

    cimgui.igGetIO().*.BackendRendererUserData = null;

    init_info = std.mem.zeroes(imgui_c.ImGui_ImplDX12_InitInfo);
    init_info.Device = @ptrCast(device);
    init_info.CommandQueue = @ptrCast(state.native.queue);
    init_info.NumFramesInFlight = @intCast(swapchain_desc.BufferCount);
    init_info.RTVFormat = @intFromEnum(bb_desc.Format);
    init_info.DSVFormat = @intFromEnum(dxgi.common.DXGI_FORMAT_UNKNOWN);
    init_info.SrvDescriptorHeap = @ptrCast(state.srv_desc_heap);
    init_info.LegacySingleSrvCpuDescriptor = .{ .ptr = getCpuSrv(device, .imgui_font_vr).ptr };
    init_info.LegacySingleSrvGpuDescriptor = .{ .ptr = getGpuSrv(device, .imgui_font_vr).ptr };

    if (!imgui_c.ImGui_ImplDX12_Init(&init_info)) {
        return error.ImGuiVRInitFailed;
    }

    state.imgui_backend_datas[1] = cimgui.igGetIO().*.BackendRendererUserData;

    log.info("Plugin D3D12 for ImGui Initialized!", .{});

    state.initialized = true;
}

pub fn deinit() void {
    if (!state.initialized) return;

    state.initialized = false;
}

pub fn updateNative(param: d3d.D3D12.VerifiedParam) void {
    if (!state.initialized) return;

    const new_native = d3d.D3D12.init(param);

    if (new_native.device != state.native.device) {
        std.log.warn("D3D12 device was different", .{});
    }
    if (new_native.swapchain != state.native.swapchain) {
        std.log.warn("D3D12 Swapchain was different", .{});
    }
    if (new_native.queue != state.native.queue) {
        std.log.warn("D3D12 Command Queue was different", .{});
    }

    state.native = new_native;
}

pub fn renderImGui() !void {
    if (!state.initialized) return;
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
