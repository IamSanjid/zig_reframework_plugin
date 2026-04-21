const re = @import("reframework");

const interop = re.interop;

pub const PlayerEquipment = interop.ManagedObject("app.PlayerEquipment", .{
    .consumeLoading = .{
        .params = .{
            .{ .type_name = "System.Int32", .type = i32 },
        },
    },
}, .{});

pub const HitPoint = interop.ManagedObject("app.HitPoint", .{
    .set_Invincible = .{
        .params = .{
            .{ .type_name = "System.Boolean", .type = bool },
        },
    },
    .get_CurrentMaximumHitPoint = .{
        .params = .{},
        .ret = .{ .type = i32 },
    },
    .get_CurrentHitPoint = .{
        .params = .{},
        .ret = .{ .type = i32 },
    },
    .resetHitPoint = .{
        .params = .{
            .{ .type_name = "System.Int32", .type = i32 },
        },
    },
}, .{});

pub const PlayerContext = interop.ManagedObject("app.PlayerContext", .{
    .get_HitPoint = .{
        .params = .{},
        .ret = .{ .type = HitPoint },
    },
}, .{});

pub const CharacterManager = interop.ManagedObject("app.CharacterManager", .{
    .getPlayerContextRef = .{
        .params = .{},
        .ret = .{ .type = ?PlayerContext },
    },
}, .{});

pub const ItemManager = interop.ManagedObject("app.ItemManager", .{}, .{
    ._InfinityGun = .{ .type = bool },
    ._InfinityAxe = .{ .type = bool },
    ._InfinityRocketLauncher = .{ .type = bool },
});
