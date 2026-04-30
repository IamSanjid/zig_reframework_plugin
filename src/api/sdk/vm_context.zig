const API = @import("API");
const Verified = @import("../verified.zig").Verified;

pub const VmContext = extern struct {
    raw: API.REFrameworkVMContextHandle,

    const Self = @This();

    pub inline fn handle(self: Self) API.REFrameworkVMContextHandle {
        return self.raw;
    }

    pub inline fn hasException(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .vm_context = .has_exception })) bool {
        return sdk.safe().vm_context.safe().has_exception(self.handle());
    }

    pub inline fn unhandledException(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .vm_context = .unhandled_exception })) void {
        sdk.safe().vm_context.safe().unhandled_exception(self.handle());
    }

    pub inline fn localFrameGc(self: Self, sdk: Verified(API.REFrameworkSDKData, .{ .vm_context = .local_frame_gc })) void {
        sdk.safe().vm_context.safe().local_frame_gc(self.handle());
    }

    pub inline fn cleanupAfterException(
        self: Self,
        sdk: Verified(API.REFrameworkSDKData, .{ .vm_context = .cleanup_after_exception }),
        old_reference_count: i32,
    ) void {
        sdk.safe().vm_context.safe().cleanup_after_exception(self.handle(), old_reference_count);
    }
};