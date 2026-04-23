const std = @import("std");
const API = @import("API");
const build_options = @import("build_options");

pub const sdk = @import("api/sdk.zig");

pub const InvokeRet = @import("api/invoke_ret.zig").InvokeRet;

const re_enums = @import("api/re_enums.zig");
pub const HookCall = re_enums.HookCall;
pub const CreateInstanceFlags = re_enums.CreateInstanceFlags;
pub const VmObjType = re_enums.VmObjType;
pub const RendererType = re_enums.RendererType;

const re_error = @import("api/re_error.zig");
pub const REFrameworkError = re_error.REFrameworkError;
pub const mapResult = re_error.mapResult;

const verified = @import("api/verified.zig");
pub const Verified = verified.Verified;

pub const specs = @import("specs.zig");

pub const VerifiedMinimal = Verified(API.REFrameworkPluginInitializeParam, specs.minimal);
pub const VerifiedFull = Verified(API.REFrameworkPluginInitializeParam, .all_recursive);

pub inline fn VerifiedSdk(comptime spec: anytype) type {
    return Verified(API.REFrameworkSDKData, spec);
}

pub inline fn VerifiedParam(comptime spec: anytype) type {
    return Verified(API.REFrameworkPluginInitializeParam, spec);
}

pub const Api = struct {
    param: VerifiedParamInit,

    const Self = @This();
    const VerifiedParamInit = VerifiedParam(if (build_options.d3d != build_options.D3D_NO_RENDERER)
        .{
            .functions = specs.minimal.functions,
            .renderer_data = .{.renderer_type},
        }
    else
        .{
            .functions = specs.minimal.functions,
        });

    pub fn init(param: [*c]const API.REFrameworkPluginInitializeParam) !Self {
        return .{ .param = try VerifiedParamInit.init(param) };
    }

    pub inline fn verifiedParam(
        self: *const Self,
        comptime spec: anytype,
    ) !Verified(API.REFrameworkPluginInitializeParam, spec) {
        return Verified(API.REFrameworkPluginInitializeParam, spec).init(self.param.native);
    }

    pub inline fn verifiedSdk(
        self: *const Self,
        comptime spec: anytype,
    ) !VerifiedSdk(spec) {
        const vp = try self.verifiedParam(.sdk);
        return Verified(API.REFrameworkSDKData, spec).init(vp.safe().sdk);
    }

    pub inline fn lockLua(self: *const Self) void {
        self.param.safe().functions.safe().lock_lua();
    }

    pub inline fn unlockLua(self: *const Self) void {
        self.param.safe().functions.safe().unlock_lua();
    }

    /// Follows `printf` formatting, have to convert all the literals, and types
    /// into C primitive types or equivalents, eg. @as(c_int, 69) or some_z.ptr([:0]const u8).
    /// It's recommended to use std.fmt.bufPrintZ or equivalent and then pass the string ptr.
    pub inline fn logError(self: *const Self, fmt: [:0]const u8, args: anytype) void {
        const f = self.param.safe().functions.safe().log_error;
        @call(.auto, f, .{fmt.ptr} ++ args);
    }

    /// Follows `printf` formatting, have to convert all the literals, and types
    /// into C primitive types or equivalents, eg. @as(c_int, 69) or some_z.ptr([:0]const u8).
    /// It's recommended to use std.fmt.bufPrintZ or equivalent and then pass the string ptr.
    pub inline fn logWarn(self: *const Self, fmt: [:0]const u8, args: anytype) void {
        const f = self.param.safe().functions.safe().log_warn;
        @call(.auto, f, .{fmt.ptr} ++ args);
    }

    /// Follows `printf` formatting, have to convert all the literals, and types
    /// into C primitive types or equivalents, eg. @as(c_int, 69) or some_z.ptr([:0]const u8).
    /// It's recommended to use std.fmt.bufPrintZ or equivalent and then pass the string ptr.
    pub inline fn logInfo(self: *const Self, fmt: [:0]const u8, args: anytype) void {
        const f = self.param.safe().functions.safe().log_info;
        @call(.auto, f, .{fmt.ptr} ++ args);
    }

    pub inline fn isDrawingUI(self: *const Self) bool {
        return self.param.safe().functions.safe().is_drawing_ui();
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
