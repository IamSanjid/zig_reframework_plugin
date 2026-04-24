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

pub const AchievementManager = interop.ManagedObject("app.AchievementManager", .{}, .{
    ._TotalClearPoint = .{ .type = u64 },
});

pub const InvenotryUser = interop.ManagedObject("app.InventoryUser", .{}, .{
    .User00 = .{ .type = .self },
    .User01 = .{ .type = .self },
    .User02 = .{ .type = .self },
    .User03 = .{ .type = .self },
    .None = .{ .type = .self },
});

pub const InventoryType = enum(c_int) {
    hand = 0,
    itembox = 1,
    shareitembox = 2,
};

pub const Inventory = interop.ManagedObject("app.Inventory", .{
    .mergeMoneys = .{
        .params = .{
            .{ .type_name = "System.Int32", .type = i32 },
        },
    },
}, .{
    ._Moneys = .{ .type = i32 },
});

pub const InventoryManager = interop.ManagedObject("app.InventoryManager", .{
    .getInventory = .{
        .params = .{
            .{ .type_name = "app.InventoryUser", .type = InvenotryUser },
            .{ .type_name = "app.InventoryType", .type = InventoryType },
        },
        .ret = .{ .type = ?Inventory },
    },
}, .{});
