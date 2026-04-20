const build_options = @import("build_options");

pub const D3D11 = if (build_options.d3d == build_options.D3D_DX11 or build_options.d3d == build_options.D3D_DX11_DX12)
    @import("d3d/D3D11.zig")
else
    struct {};

pub const D3D12 = if (build_options.d3d == build_options.D3D_DX12 or build_options.d3d == build_options.D3D_DX11_DX12)
    @import("d3d/D3D12.zig")
else
    struct {};

test {
    @import("std").testing.refAllDecls(@This());
}
