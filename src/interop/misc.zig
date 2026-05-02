pub inline fn isSafeMode() bool {
    const builtin = @import("builtin");
    return !builtin.is_test and
        (builtin.mode == .Debug or builtin.mode == .ReleaseSafe);
}
