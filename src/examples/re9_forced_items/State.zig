const std = @import("std");

const re = @import("reframework");

api: re.api.Api,
sdk: re.api.VerifiedSdk(re.api.specs.minimal.sdk),
allocator: std.mem.Allocator,
io: std.Io,
interop_cache: re.interop.ManagedTypeCache,

const State = @This();

pub fn init(allocator: std.mem.Allocator, io: std.Io) State {
    return State{
        .api = undefined,
        .sdk = undefined,
        .allocator = allocator,
        .io = io,
        .interop_cache = .init(allocator, io),
    };
}
