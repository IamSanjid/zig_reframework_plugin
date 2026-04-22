const windows = @import("std").os.windows;
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

pub const Native = struct {
    raw: *anyopaque,

    pub inline fn as(self: @This(), comptime DeviceType: type) if (@typeInfo(DeviceType) == .pointer)
        DeviceType
    else
        *DeviceType {
        return @ptrCast(@alignCast(self.raw));
    }
};

device: Native,
swapchain: Native,

const D3D11 = @This();

pub fn init(param: VerifiedParam) D3D11 {
    const renderer_data = param.safe().renderer_data.safe();

    return .{
        .device = .{ .raw = renderer_data.device },
        .swapchain = .{ .raw = renderer_data.swapchain },
    };
}

pub fn getHwnd(self: *const D3D11) !?windows.HWND {
    return @ptrCast((try self.getSwapChainDesc()).OutputWindow);
}

inline fn getSwapChainDesc(self: *const D3D11) !dxgi.DXGI_SWAP_CHAIN_DESC {
    var desc: dxgi.DXGI_SWAP_CHAIN_DESC = undefined;
    if (win32.zig.FAILED(self.swapchain.as(dxgi.IDXGISwapChain).GetDesc(&desc))) return error.SwapChainDescFailed;
    return desc;
}

test {
    @import("std").testing.refAllDecls(@This());
}
