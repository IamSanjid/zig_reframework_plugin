const d3d = @import("reframework").d3d;
const win32 = @import("win32");

const state = struct {
    var native: d3d.D3D12 = undefined;
};

pub fn init(param: d3d.D3D12.VerifiedParam) !void {
    state.native = .init(param);
}
