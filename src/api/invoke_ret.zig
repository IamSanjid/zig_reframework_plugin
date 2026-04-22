pub const InvokeRet = extern struct {
    bytes: [128]u8 = [_]u8{0} ** 128,
    exception_thrown: bool = false,

    pub inline fn asU8(self: *const InvokeRet) u8 {
        return self.bytes[0];
    }

    pub inline fn asU16(self: *const InvokeRet) u16 {
        return @bitCast(self.bytes[0..2].*);
    }

    pub inline fn asU32(self: *const InvokeRet) u32 {
        return @bitCast(self.bytes[0..4].*);
    }

    pub inline fn asU64(self: *const InvokeRet) u64 {
        return @bitCast(self.bytes[0..8].*);
    }

    pub inline fn asUsize(self: *const InvokeRet) usize {
        return @bitCast(self.bytes[0..@sizeOf(usize)].*);
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
