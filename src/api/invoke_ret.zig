const std = @import("std");
const native = std.builtin.Endian.native;

pub const InvokeRet = extern struct {
    bytes: [128]u8 = [_]u8{0} ** 128,
    exception_thrown: bool = false,

    pub inline fn as(self: *const InvokeRet, T: type) T {
        if (@typeInfo(T) != .int or @typeInfo(T).int.bits > @sizeOf(u128) * std.mem.byte_size_in_bits) {
            @compileError("Unsupported type for InvokeRet.as: " ++ @typeName(T));
        }
        return std.mem.readInt(T, self.bytes[0..@sizeOf(T)], native);
    }

    pub inline fn asU8(self: *const InvokeRet) u8 {
        return self.bytes[0];
    }

    pub inline fn asU16(self: *const InvokeRet) u16 {
        return self.as(u16);
    }

    pub inline fn asU32(self: *const InvokeRet) u32 {
        return self.as(u32);
    }

    pub inline fn asU64(self: *const InvokeRet) u64 {
        return self.as(u64);
    }

    pub inline fn asUsize(self: *const InvokeRet) usize {
        return self.as(usize);
    }

    pub inline fn asF32(self: *const InvokeRet) f32 {
        return @bitCast(self.asU32());
    }

    pub inline fn asF64(self: *const InvokeRet) f64 {
        return @bitCast(self.asU64());
    }

    pub inline fn asPtr(self: *const InvokeRet) ?*anyopaque {
        return @ptrFromInt(self.asUsize());
    }

    pub inline fn setPtr(self: *InvokeRet, p: ?*anyopaque) void {
        const addr: usize = @intFromPtr(p); // null => 0
        const raw: [@sizeOf(usize)]u8 = @bitCast(addr);
        @memcpy(self.bytes[0..@sizeOf(usize)], &raw);
    }
};

comptime {
    std.debug.assert(@sizeOf(InvokeRet) == 129); // 128 + 1
    std.debug.assert(@offsetOf(InvokeRet, "exception_thrown") == 128);
}
