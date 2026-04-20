const win32 = @import("win32");

const API = @import("API");
const Verified = @import("../api/verified.zig").Verified;

const d3d12 = win32.graphics.direct3d12;
const dxgi = win32.graphics.dxgi;

pub const VerifiedParam = Verified(API.REFrameworkPluginInitializeParam, .{
    .renderer_data = .{
        .renderer_type,
        .device,
        .swapchain,
        .command_queue,
    },
});

device: *d3d12.ID3D12Device,
queue: *d3d12.ID3D12CommandQueue,
swapchain: *dxgi.IDXGISwapChain3,

const D3D12 = @This();

pub fn swapchainBase(self: *const D3D12) *dxgi.IDXGISwapChain {
    return @ptrCast(self.swapchain);
}

pub fn init(param: VerifiedParam) D3D12 {
    const renderer_data = param.safe().renderer_data;

    const device: *d3d12.ID3D12Device = @ptrCast(@alignCast(renderer_data.safe().device));
    const queue: *d3d12.ID3D12CommandQueue = @ptrCast(@alignCast(renderer_data.safe().command_queue));
    const swapchain: *dxgi.IDXGISwapChain3 = @ptrCast(@alignCast(renderer_data.safe().swapchain));

    return .{
        .device = device,
        .queue = queue,
        .swapchain = swapchain,
    };
}

pub fn getHwnd(self: *const D3D12) !?win32.foundation.HWND {
    return (try self.getSwapChainDesc()).OutputWindow;
}

pub fn getSwapChainDesc(self: *const D3D12) !dxgi.DXGI_SWAP_CHAIN_DESC {
    var desc: dxgi.DXGI_SWAP_CHAIN_DESC = undefined;
    if (self.swapchainBase().GetDesc(&desc) < 0) return error.SwapChainDescFailed;
    return desc;
}

test {
    @import("std").testing.refAllDecls(@This());
}
