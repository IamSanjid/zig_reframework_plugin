const std = @import("std");
const API = @import("API");
const Verified = @import("../verified.zig").Verified;
const InvokeRet = @import("../invoke_ret.zig").InvokeRet;

const re_error = @import("../re_error.zig");
const REFrameworkError = re_error.REFrameworkError;

const TypeDefinition = @import("TypeDefinition.zig");
const HookCall = @import("../re_enums.zig").HookCall;

raw: API.REFrameworkMethodHandle,

const Method = @This();

pub const Parameter = struct {
    raw: API.REFrameworkMethodParameter,

    const Self = @This();

    pub inline fn name(self: Self) [:0]const u8 {
        return std.mem.span(self.raw.name);
    }

    pub inline fn typeDefinition(self: Self) TypeDefinition {
        return .{ .raw = self.raw.t };
    }
};

pub inline fn handle(self: Method) API.REFrameworkMethodHandle {
    return self.raw;
}

pub fn invoke(
    self: Method,
    sdk: Verified(API.REFrameworkSDKData, .{ .method = .invoke }),
    thisptr: ?*anyopaque,
    args: []?*anyopaque,
) REFrameworkError!InvokeRet {
    var out: InvokeRet = .{};
    const result = sdk.safe().method.safe().invoke(
        self.handle(),
        thisptr,
        if (args.len == 0) null else @ptrCast(args.ptr),
        @intCast(args.len * @sizeOf(?*anyopaque)),
        &out,
        @sizeOf(InvokeRet),
    );
    try re_error.mapResult(result);
    return out;
}

pub inline fn invokeNoArgs(
    self: Method,
    sdk: Verified(API.REFrameworkSDKData, .{ .method = .invoke }),
    thisptr: ?*anyopaque,
) REFrameworkError!InvokeRet {
    return self.invoke(sdk, thisptr, &.{});
}

pub inline fn getFunctionRaw(self: Method, sdk: Verified(API.REFrameworkSDKData, .{ .method = .get_function })) ?*anyopaque {
    return sdk.safe().method.safe().get_function(self.handle());
}

pub inline fn getFunction(self: Method, FuncT: type, sdk: Verified(API.REFrameworkSDKData, .{ .method = .get_function })) ?*const FuncT {
    const raw = self.getFunctionRaw(sdk) orelse return null;
    return @ptrCast(raw);
}

pub inline fn getName(self: Method, sdk: Verified(API.REFrameworkSDKData, .{ .method = .get_name })) ?[:0]const u8 {
    const value = sdk.safe().method.safe().get_name(self.handle()) orelse return null;
    return std.mem.span(value);
}

pub inline fn getDeclaringType(self: Method, sdk: Verified(API.REFrameworkSDKData, .{ .method = .get_declaring_type })) ?TypeDefinition {
    const result = sdk.safe().method.safe().get_declaring_type(self.handle());
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub inline fn getReturnType(self: Method, sdk: Verified(API.REFrameworkSDKData, .{ .method = .get_return_type })) ?TypeDefinition {
    const result = sdk.safe().method.safe().get_return_type(self.handle());
    return if (result) |value| .{ .raw = @ptrCast(value) } else null;
}

pub inline fn getNumParams(self: Method, sdk: Verified(API.REFrameworkSDKData, .{ .method = .get_num_params })) u32 {
    return sdk.safe().method.safe().get_num_params(self.handle());
}

pub fn getParams(
    self: Method,
    sdk: Verified(API.REFrameworkSDKData, .{ .method = .get_params }),
    out: []Parameter,
) REFrameworkError![]Parameter {
    var out_count: c_uint = 0;
    const result = sdk.safe().method.safe().get_params(
        self.handle(),
        @ptrCast(out.ptr),
        @intCast(out.len * @sizeOf(API.REFrameworkMethodParameter)),
        &out_count,
    );
    try re_error.mapResult(result);
    if (out_count > out.len) return error.OutTooSmall;
    return out[0..out_count];
}

pub inline fn isStatic(self: Method, sdk: Verified(API.REFrameworkSDKData, .{ .method = .is_static })) bool {
    return sdk.safe().method.safe().is_static(self.handle());
}

pub inline fn getFlags(self: Method, sdk: Verified(API.REFrameworkSDKData, .{ .method = .get_flags })) u16 {
    return sdk.safe().method.safe().get_flags(self.handle());
}

pub inline fn getImplFlags(self: Method, sdk: Verified(API.REFrameworkSDKData, .{ .method = .get_impl_flags })) u16 {
    return sdk.safe().method.safe().get_impl_flags(self.handle());
}

pub inline fn getInvokeId(self: Method, sdk: Verified(API.REFrameworkSDKData, .{ .method = .get_invoke_id })) u32 {
    return sdk.safe().method.safe().get_invoke_id(self.handle());
}

const PreHookZigFn = fn (?[]?*anyopaque, ?[]TypeDefinition, u64) HookCall;
const PostHookZigFn = fn (?*?*anyopaque, TypeDefinition, u64) void;

fn preZigFnToC(comptime func: PreHookZigFn) API.REFPreHookFn {
    return &struct {
        fn cFunc(argc: i32, argv: [*c]?*anyopaque, arg_tys: [*c]API.REFrameworkTypeDefinitionHandle, ret_addr: u64) callconv(.c) i32 {
            const passing_argv: ?[]?*anyopaque = blk: {
                if (argv != null) {
                    const raw_argv: [*]?*anyopaque = @ptrCast(argv);
                    break :blk raw_argv[0..@intCast(argc)];
                }
                break :blk null;
            };
            const passing_arg_tys: ?[]TypeDefinition = blk: {
                if (arg_tys != null) {
                    const raw_arg_tys: [*]API.REFrameworkTypeDefinitionHandle = @ptrCast(arg_tys);
                    const raw_arg_slice: []API.REFrameworkTypeDefinitionHandle = raw_arg_tys[0..@intCast(argc)];
                    break :blk @ptrCast(raw_arg_slice);
                }
                break :blk null;
            };
            return @intFromEnum(func(passing_argv, passing_arg_tys, ret_addr));
        }
    }.cFunc;
}

fn postZigFnToC(comptime func: PostHookZigFn) API.REFPostHookFn {
    return &struct {
        fn cFunc(ret_val: [*c]?*anyopaque, type_def: API.REFrameworkTypeDefinitionHandle, ret_addr: u64) callconv(.c) void {
            const passing_ret_val: ?*?*anyopaque = blk: {
                if (ret_val != null) {
                    const raw_ret_val: [*]?*anyopaque = @ptrCast(ret_val);
                    break :blk @ptrCast(raw_ret_val);
                }
                break :blk null;
            };
            func(passing_ret_val, .{ .raw = type_def }, ret_addr);
        }
    }.cFunc;
}

pub inline fn addHookC(
    self: Method,
    sdkf: Verified(API.REFrameworkSDKFunctions, .add_hook),
    pre: API.REFPreHookFn,
    post: API.REFPostHookFn,
    ignore_jmp: bool,
) u32 {
    return sdkf.safe().add_hook(self.handle(), pre, post, ignore_jmp);
}

pub fn addHook(
    self: Method,
    sdkf: Verified(API.REFrameworkSDKFunctions, .add_hook),
    comptime pre: ?PreHookZigFn,
    comptime post: ?PostHookZigFn,
    ignore_jmp: bool,
) u32 {
    const pre_c: API.REFPreHookFn = if (pre) |func| blk: {
        break :blk preZigFnToC(func);
    } else null;
    const post_c: API.REFPostHookFn = if (post) |func| blk: {
        break :blk postZigFnToC(func);
    } else null;
    return self.addHookC(sdkf, pre_c, post_c, ignore_jmp);
}

pub inline fn removeHook(
    self: Method,
    sdkf: Verified(API.REFrameworkSDKFunctions, .remove_hook),
    hook_id: u32,
) void {
    sdkf.safe().remove_hook(self.handle(), hook_id);
}
