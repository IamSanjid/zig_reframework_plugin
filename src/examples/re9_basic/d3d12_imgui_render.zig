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
    backbuffer_0,
    backbuffer_1,
    backbuffer_2,
    backbuffer_3,
    imgui,
    blank,
    count,
};

const SRV = enum(u32) {
    imgui_font,
    imgui,
    blank,
    count,
};

const ImGui_ImplDX12_Texture = extern struct {
    pTextureResource: ?*d3d12.ID3D12Resource,
    hFontSrvCpuDescHandle: d3d12.D3D12_CPU_DESCRIPTOR_HANDLE,
    hFontSrvGpuDescHandle: d3d12.D3D12_GPU_DESCRIPTOR_HANDLE,
};

const ImGui_ImplDX12_Data = extern struct {
    InitInfo: imgui_c.ImGui_ImplDX12_InitInfo,
    pd3dDevice: ?*d3d12.ID3D12Device,
    pRootSignature: ?*d3d12.ID3D12RootSignature,
    pPipelineState: ?*d3d12.ID3D12PipelineState,
    pCommandQueue: ?*d3d12.ID3D12CommandQueue,
    commandQueueOwned: bool,
    RTVFormat: dxgi.common.DXGI_FORMAT,
    DSVFormat: dxgi.common.DXGI_FORMAT,
    pd3dSrvDescHeap: ?*d3d12.ID3D12DescriptorHeap,
    numFramesInFlight: windows.UINT,
    pFrameResources: ?*anyopaque,
    frameIndex: windows.UINT,
    FontTexture: ImGui_ImplDX12_Texture,
    LegacySingleDescriptorUsed: bool,
};

const state = struct {
    var initialized = false;
    var native: d3d.D3D12 = undefined;
    var cmd_allocator: *d3d12.ID3D12CommandAllocator = undefined;
    var cmd_list: *d3d12.ID3D12GraphicsCommandList = undefined;
    var rtv_desc_heap: *d3d12.ID3D12DescriptorHeap = undefined;
    var srv_desc_heap: *d3d12.ID3D12DescriptorHeap = undefined;
    var rts: [@intFromEnum(RTV.count)]*d3d12.ID3D12Resource = undefined;
    var rt_width: u64 = 0;
    var rt_height: u64 = 0;
};

pub fn init(param: d3d.D3D12.VerifiedParam) !void {
    if (state.initialized) return;

    state.native = .init(param);

    if (FAILED(state.native.device.CreateCommandAllocator(.DIRECT, d3d12.IID_ID3D12CommandAllocator, @ptrCast(&state.cmd_allocator)))) {
        return error.CreateCommandAllocatorFailed;
    }
    errdefer _ = state.cmd_allocator.IUnknown.Release();

    if (FAILED(state.native.device.CreateCommandList(0, .DIRECT, state.cmd_allocator, null, d3d12.IID_ID3D12CommandList, @ptrCast(&state.cmd_list)))) {
        return error.CreateCommandListFailed;
    }
    errdefer _ = state.cmd_list.IUnknown.Release();

    if (FAILED(state.cmd_list.Close())) {
        return error.CloseCommandListFailed;
    }

    {
        const desc = d3d12.D3D12_DESCRIPTOR_HEAP_DESC{
            .Type = .RTV,
            .NumDescriptors = @intFromEnum(RTV.count),
            .Flags = .{},
            .NodeMask = 1,
        };
        if (FAILED(state.native.device.CreateDescriptorHeap(&desc, d3d12.IID_ID3D12DescriptorHeap, @ptrCast(&state.rtv_desc_heap)))) {
            return error.CreateRtvDescriptorHeapFailed;
        }
    }
    errdefer _ = state.rtv_desc_heap.IUnknown.Release();

    {
        const desc = d3d12.D3D12_DESCRIPTOR_HEAP_DESC{
            .Type = .CBV_SRV_UAV,
            .NumDescriptors = @intFromEnum(SRV.count),
            .Flags = .{ .SHADER_VISIBLE = 1 },
            .NodeMask = 0,
        };
        if (FAILED(state.native.device.CreateDescriptorHeap(&desc, d3d12.IID_ID3D12DescriptorHeap, @ptrCast(&state.srv_desc_heap)))) {
            return error.CreateSrvDescriptorHeapFailed;
        }
    }
    errdefer _ = state.srv_desc_heap.IUnknown.Release();

    for (0..@intFromEnum(RTV.backbuffer_3) + 1) |i| {
        if (SUCCEEDED(state.native.swapchain.IDXGISwapChain.GetBuffer(@truncate(i), d3d12.IID_ID3D12Resource, @ptrCast(&state.rts[i])))) {
            state.native.device.CreateRenderTargetView(state.rts[i], null, getCpuRtv(state.native.device, @enumFromInt(i)));
        }
    }

    // create our imgui and blank rts
    const desc = getRt(.backbuffer_0).GetDesc();

    const props = d3d12.D3D12_HEAP_PROPERTIES{
        .Type = .DEFAULT,
        .CPUPageProperty = .UNKNOWN,
        .MemoryPoolPreference = .UNKNOWN,
        .CreationNodeMask = 0,
        .VisibleNodeMask = 0,
    };

    const clear_value = d3d12.D3D12_CLEAR_VALUE{
        .Format = desc.Format,
        .Anonymous = .{
            .Color = .{ 0.0, 0.0, 0.0, 0.0 },
        },
    };

    if (FAILED(state.native.device.CreateCommittedResource(
        &props,
        .{},
        &desc,
        .{ .PIXEL_SHADER_RESOURCE = 1 },
        &clear_value,
        d3d12.IID_ID3D12Resource,
        @ptrCast(@constCast(&getRt(.imgui))),
    ))) {
        return error.CreateImguiRtFailed;
    }
    errdefer _ = getRt(.imgui).IUnknown.Release();

    if (FAILED(state.native.device.CreateCommittedResource(
        &props,
        .{},
        &desc,
        .{ .PIXEL_SHADER_RESOURCE = 1 },
        &clear_value,
        d3d12.IID_ID3D12Resource,
        @ptrCast(@constCast(&getRt(.blank))),
    ))) {
        return error.CreateBlankRtFailed;
    }
    errdefer _ = getRt(.blank).IUnknown.Release();

    // Create imgui and blank rtvs and srvs.
    state.native.device.CreateRenderTargetView(getRt(.imgui), null, getCpuRtv(state.native.device, .imgui));
    state.native.device.CreateRenderTargetView(getRt(.blank), null, getCpuRtv(state.native.device, .blank));
    state.native.device.CreateShaderResourceView(getRt(.imgui), null, getCpuSrv(state.native.device, .imgui));
    state.native.device.CreateShaderResourceView(getRt(.blank), null, getCpuSrv(state.native.device, .blank));

    state.rt_width = desc.Width;
    state.rt_height = desc.Height;

    var init_info: imgui_c.ImGui_ImplDX12_InitInfo = .{
        .Device = @ptrCast(state.native.device),
        .CommandQueue = @ptrCast(state.native.queue),
        .NumFramesInFlight = 1,
        .RTVFormat = @intFromEnum(dxgi.common.DXGI_FORMAT_R8G8B8A8_UNORM),
        .SrvDescriptorHeap = @ptrCast(state.srv_desc_heap),
        .LegacySingleSrvCpuDescriptor = .{ .ptr = getCpuSrv(state.native.device, .imgui_font).ptr },
        .LegacySingleSrvGpuDescriptor = .{ .ptr = getGpuSrv(state.native.device, .imgui_font).ptr },
    };
    if (!imgui_c.ImGui_ImplDX12_Init(&init_info)) {
        return error.ImGuiImplDx12InitFailed;
    }

    // if (!imgui_c.ImGui_ImplDX12_InitLegacy(
    //     @ptrCast(state.native.device),
    //     1,
    //     @intFromEnum(dxgi.common.DXGI_FORMAT_R8G8B8A8_UNORM),
    //     @ptrCast(state.srv_desc_heap),
    //     .{ .ptr = getCpuSrv(state.native.device, .imgui_font).ptr },
    //     .{ .ptr = getGpuSrv(state.native.device, .imgui_font).ptr },
    // )) {
    //     return error.ImGuiImplDx12InitFailed;
    // }
    const bd: *ImGui_ImplDX12_Data = @ptrCast(@alignCast(cimgui.igGetIO().*.BackendRendererUserData));
    bd.*.commandQueueOwned = false;
    cimgui.igGetIO().*.BackendFlags &= ~cimgui.ImGuiBackendFlags_RendererHasTextures;

    state.initialized = true;
}

pub fn deinit() void {
    if (!state.initialized) return;

    _ = getRt(.blank).IUnknown.Release();
    _ = getRt(.imgui).IUnknown.Release();
    _ = state.srv_desc_heap.IUnknown.Release();
    _ = state.rtv_desc_heap.IUnknown.Release();
    _ = state.cmd_list.IUnknown.Release();
    _ = state.cmd_allocator.IUnknown.Release();

    state.initialized = false;
}

pub fn renderImGui(param: d3d.D3D12.VerifiedParam) !void {
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

    const bd: *ImGui_ImplDX12_Data = @ptrCast(@alignCast(cimgui.igGetIO().*.BackendRendererUserData));
    bd.*.pCommandQueue = @ptrCast(state.native.queue);

    _ = state.cmd_allocator.Reset();
    _ = state.cmd_list.Reset(state.cmd_allocator, null);

    // Draw to our render target
    var barier = d3d12.D3D12_RESOURCE_BARRIER{
        .Type = .TRANSITION,
        .Flags = .{},
        .Anonymous = .{
            .Transition = .{
                .pResource = getRt(.imgui),
                .StateBefore = .{ .PIXEL_SHADER_RESOURCE = 1 },
                .StateAfter = .{ .RENDER_TARGET = 1 },
                .Subresource = d3d12.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
            },
        },
    };
    state.cmd_list.ResourceBarrier(1, @ptrCast(&barier));

    const clear_color: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 };
    const device = state.native.device;
    const empty_rect: []win32.foundation.RECT = &.{};
    state.cmd_list.ClearRenderTargetView(getCpuRtv(device, .imgui), &clear_color[0], 0, empty_rect.ptr);
    var rts = [1]d3d12.D3D12_CPU_DESCRIPTOR_HANDLE{
        getCpuRtv(device, .imgui),
    };
    state.cmd_list.OMSetRenderTargets(1, &rts[0], FALSE, null);
    state.cmd_list.SetDescriptorHeaps(1, @ptrCast(&state.srv_desc_heap));
    imgui_c.ImGui_ImplDX12_RenderDrawData(@ptrCast(cimgui.igGetDrawData()), @ptrCast(state.cmd_list));
    barier.Anonymous.Transition.StateBefore = .{ .RENDER_TARGET = 1 };
    barier.Anonymous.Transition.StateAfter = .{ .PIXEL_SHADER_RESOURCE = 1 };
    state.cmd_list.ResourceBarrier(1, @ptrCast(&barier));

    // Draw to the backbuffer
    const swapchain = state.native.swapchain;
    const bb_index = swapchain.GetCurrentBackBufferIndex();
    barier.Anonymous.Transition.pResource = getRt(@enumFromInt(bb_index));
    barier.Anonymous.Transition.StateBefore = d3d12.D3D12_RESOURCE_STATE_PRESENT;
    barier.Anonymous.Transition.StateAfter = .{ .RENDER_TARGET = 1 };
    state.cmd_list.ResourceBarrier(1, @ptrCast(&barier));
    rts[0] = getCpuRtv(device, @enumFromInt(bb_index));
    state.cmd_list.OMSetRenderTargets(1, &rts[0], FALSE, null);
    state.cmd_list.SetDescriptorHeaps(1, @ptrCast(&state.srv_desc_heap));
    imgui_c.ImGui_ImplDX12_RenderDrawData(@ptrCast(cimgui.igGetDrawData()), @ptrCast(state.cmd_list));
    barier.Anonymous.Transition.StateBefore = .{ .RENDER_TARGET = 1 };
    barier.Anonymous.Transition.StateAfter = d3d12.D3D12_RESOURCE_STATE_PRESENT;
    state.cmd_list.ResourceBarrier(1, @ptrCast(&barier));
    _ = state.cmd_list.Close();

    state.native.queue.ExecuteCommandLists(1, @ptrCast(&state.cmd_list));
}

inline fn getRt(rtv: RTV) *d3d12.ID3D12Resource {
    return state.rts[@intFromEnum(rtv)];
}

fn getCpuRtv(device: *d3d12.ID3D12Device, rtv: RTV) d3d12.D3D12_CPU_DESCRIPTOR_HANDLE {
    return .{ .ptr = state.rtv_desc_heap.GetCPUDescriptorHandleForHeapStart().ptr +
        @intFromEnum(rtv) * device.GetDescriptorHandleIncrementSize(.RTV) };
}

fn getCpuSrv(device: *d3d12.ID3D12Device, srv: SRV) d3d12.D3D12_CPU_DESCRIPTOR_HANDLE {
    return .{ .ptr = state.srv_desc_heap.GetCPUDescriptorHandleForHeapStart().ptr +
        @intFromEnum(srv) * device.GetDescriptorHandleIncrementSize(.CBV_SRV_UAV) };
}

fn getGpuSrv(device: *d3d12.ID3D12Device, srv: SRV) d3d12.D3D12_GPU_DESCRIPTOR_HANDLE {
    return .{ .ptr = state.srv_desc_heap.GetGPUDescriptorHandleForHeapStart().ptr +
        @intFromEnum(srv) * device.GetDescriptorHandleIncrementSize(.CBV_SRV_UAV) };
}

test {
    @import("std").testing.refAllDecls(@This());
}
