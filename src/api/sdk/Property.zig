const API = @import("API");

raw: API.REFrameworkPropertyHandle,

const Property = @This();

pub inline fn handle(self: Property) API.REFrameworkPropertyHandle {
    return self.raw;
}

// TODO: Update with REFramework
