const win32 = @import("win32");

const API = @import("API");
const Verified = @import("../api/verified.zig").Verified;

const d3d11 = win32.graphics.direct3d11;
const dxgi = win32.graphics.dxgi;

pub const VerifiedParam = Verified(API.REFrameworkPluginInitializeParam, .{
    .renderer_data = .{
        .renderer_type,
        .device,
        .swapchain,
    },
});

device: *d3d11.ID3D11Device,
swapchain: *dxgi.IDXGISwapChain3,

const D3D11 = @This();

pub fn init(param: VerifiedParam) D3D11 {
    const renderer_data = param.safe().renderer_data;
    const device: *d3d11.ID3D11Device = @ptrCast(@alignCast(renderer_data.safe().device));
    const swapchain: *dxgi.IDXGISwapChain3 = @ptrCast(@alignCast(renderer_data.safe().swapchain));

    return .{
        .device = device,
        .swapchain = swapchain,
    };
}

pub fn swapchainBase(self: *const D3D11) *dxgi.IDXGISwapChain {
    return @ptrCast(self.swapchain);
}

pub fn getHwnd(self: *const D3D11) !?win32.foundation.HWND {
    return (try self.getSwapChainDesc()).OutputWindow;
}

pub fn getSwapChainDesc(self: *const D3D11) !dxgi.DXGI_SWAP_CHAIN_DESC {
    var desc: dxgi.DXGI_SWAP_CHAIN_DESC = undefined;
    if (self.swapchainBase().GetDesc(&desc) < 0) return error.SwapChainDescFailed;
    return desc;
}

test {
    @import("std").testing.refAllDecls(@This());
}
