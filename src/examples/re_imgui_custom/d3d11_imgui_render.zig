/// Not tested should work in theory.
/// 1-to-1 https://github.com/praydog/REFramework/blob/0a74333ac76774884724bbac2ad7fefba702b6a3/src/REFramework.cpp#L2233
/// Contains some extra texture/resources for VR related, but we don't really use them.
const std = @import("std");
const d3d = @import("reframework").d3d;
const win32 = @import("win32");
const cimgui = @import("cimgui");
const imgui_c = @import("imgui_c");

const d3d11 = win32.graphics.direct3d11;
const dxgi = win32.graphics.dxgi;
const windows_programming = win32.system.windows_programming;
const windows = std.os.windows;

const FAILED = win32.zig.FAILED;
const SUCCEEDED = win32.zig.SUCCEEDED;
const FALSE = win32.zig.FALSE;

pub const g_state = struct {
    // TODO: Do we really need mutex? Don't know if on_present will be called from different threads...?
    pub var io: ?std.Io = null;
    pub var mtx: std.Io.Mutex = .init;
};

const state = struct {
    var initialized = false;
    var native: d3d.D3D11 = undefined;
    var bb_rtv: *d3d11.ID3D11RenderTargetView = undefined;
    var blank_rt: *d3d11.ID3D11Texture2D = undefined;
    var rt: *d3d11.ID3D11Texture2D = undefined;
    var blank_rt_rtv: *d3d11.ID3D11RenderTargetView = undefined;
    var rt_rtv: *d3d11.ID3D11RenderTargetView = undefined;
    var rt_srv: *d3d11.ID3D11ShaderResourceView = undefined;
    var rt_width: u32 = 0;
    var rt_height: u32 = 0;
};

const log = std.log.scoped(.d3d11_renderer);

pub fn init(d3d11_ins: d3d.D3D11) !void {
    try g_state.mtx.lock(g_state.io.?);
    defer g_state.mtx.unlock(g_state.io.?);

    if (state.initialized) return;

    state.native = d3d11_ins;

    const swapchain = state.native.swapchain.as(dxgi.IDXGISwapChain3);
    const device = state.native.device.as(d3d11.ID3D11Device);

    log.info("Creating RTV of back buffer...", .{});

    var back_buffer: *d3d11.ID3D11Texture2D = undefined;

    if (FAILED(swapchain.IDXGISwapChain.GetBuffer(0, d3d11.IID_ID3D11Texture2D, @ptrCast(&back_buffer)))) {
        return error.GetBufferFailed;
    }

    if (FAILED(device.CreateRenderTargetView(&back_buffer.ID3D11Resource, null, @ptrCast(&state.bb_rtv)))) {
        return error.CreateRenderTargetViewFailed;
    }
    errdefer _ = state.bb_rtv.IUnknown.Release();

    var backbuffer_desc: d3d11.D3D11_TEXTURE2D_DESC = std.mem.zeroes(d3d11.D3D11_TEXTURE2D_DESC);

    back_buffer.GetDesc(&backbuffer_desc);
    backbuffer_desc.BindFlags.RENDER_TARGET = 1;
    backbuffer_desc.BindFlags.SHADER_RESOURCE = 1;

    log.info("Back buffer format is {}", .{backbuffer_desc.Format});

    log.info("Creating render targets...", .{});

    var d3d11_rt_desc = backbuffer_desc;
    d3d11_rt_desc.Format = .R8G8B8A8_UNORM;

    if (FAILED(device.CreateTexture2D(&d3d11_rt_desc, null, @ptrCast(&state.blank_rt)))) {
        return error.CreateRenderTargetFailed;
    }
    errdefer _ = state.blank_rt.IUnknown.Release();

    if (FAILED(device.CreateTexture2D(&d3d11_rt_desc, null, @ptrCast(&state.rt)))) {
        return error.CreateRenderTargetFailed;
    }
    errdefer _ = state.rt.IUnknown.Release();

    log.info("Creating rtvs...", .{});

    if (FAILED(device.CreateRenderTargetView(&state.blank_rt.ID3D11Resource, null, @ptrCast(&state.blank_rt_rtv)))) {
        return error.CreateRenderTargetViewFailed;
    }
    errdefer _ = state.blank_rt_rtv.IUnknown.Release();

    if (FAILED(device.CreateRenderTargetView(&state.rt.ID3D11Resource, null, @ptrCast(&state.rt_rtv)))) {
        return error.CreateRenderTargetViewFailed;
    }
    errdefer _ = state.rt_rtv.IUnknown.Release();

    log.info("Creating srvs...", .{});

    if (FAILED(device.CreateShaderResourceView(&state.rt.ID3D11Resource, null, @ptrCast(&state.rt_srv)))) {
        return error.CreateShaderResourceViewFailed;
    }
    errdefer _ = state.rt_srv.IUnknown.Release();

    state.rt_width = backbuffer_desc.Width;
    state.rt_height = backbuffer_desc.Height;

    log.info("Initializing ImGui D3D11...", .{});

    var context: *d3d11.ID3D11DeviceContext = undefined;
    device.GetImmediateContext(@ptrCast(&context));

    if (!imgui_c.ImGui_ImplDX11_Init(@ptrCast(device), @ptrCast(context))) {
        return error.ImguiD3D11InitFailed;
    }

    state.initialized = true;
}

pub fn deinit() void {
    g_state.mtx.lockUncancelable(g_state.io.?);
    defer g_state.mtx.unlock(g_state.io.?);

    if (!state.initialized) return;

    _ = state.rt_srv.IUnknown.Release();
    _ = state.rt_rtv.IUnknown.Release();
    _ = state.blank_rt_rtv.IUnknown.Release();
    _ = state.rt.IUnknown.Release();
    _ = state.blank_rt.IUnknown.Release();
    _ = state.bb_rtv.IUnknown.Release();

    state.rt_width = 0;
    state.rt_height = 0;
    state.native = undefined;

    state.initialized = false;
}

pub fn render() !void {
    try g_state.mtx.lock(g_state.io.?);
    defer g_state.mtx.unlock(g_state.io.?);

    if (!state.initialized) return;

    const device = state.native.device.as(d3d11.ID3D11Device);

    var context: *d3d11.ID3D11DeviceContext = undefined;
    const clear_color: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 };

    device.GetImmediateContext(@ptrCast(&context));
    context.ClearRenderTargetView(state.blank_rt_rtv, &clear_color[0]);

    context.OMSetRenderTargets(1, @ptrCast(&state.rt_rtv), null);
    imgui_c.ImGui_ImplDX11_RenderDrawData(@ptrCast(cimgui.igGetDrawData()));
}
