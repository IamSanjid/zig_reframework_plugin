const API = @import("API");

pub const Property = extern struct {
    raw: API.REFrameworkPropertyHandle,

    const Self = @This();

    pub inline fn handle(self: Self) API.REFrameworkPropertyHandle {
        return self.raw;
    }
};