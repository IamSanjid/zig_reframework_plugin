const re = @import("reframework");

const interop = re.interop;

pub const PlayerEquipment = interop.ManagedObjectTypeBuilder("app.PlayerEquipment")
    .Method(.consumeLoading, void, null)
    .Param("System.Int32", i32, null)
    .Build();

pub const HitPoint = interop.ManagedObjectTypeBuilder("app.HitPoint")
    .Method(.set_Invincible, void, null)
    .Param("System.Boolean", bool, null)
    .Method(.get_CurrentMaximumHitPoint, i32, null)
    .Method(.get_CurrentHitPoint, i32, null)
    .Method(.resetHitPoint, void, null)
    .Param("System.Int32", i32, null)
    .Build();

pub const PlayerContext = interop.ManagedObjectTypeBuilder("app.PlayerContext")
    .Method(.get_HitPoint, HitPoint, null)
    .Build();

pub const CharacterManager = interop.ManagedObjectTypeBuilder("app.CharacterManager")
    .Method(.getPlayerContextRef, ?PlayerContext, null)
    .Build();

pub const ItemManager = interop.ManagedObjectTypeBuilder("app.ItemManager")
    .Field(._InfinityGun, bool, null, null)
    .Field(._InfinityAxe, bool, null, null)
    .Field(._InfinityRocketLauncher, bool, null, null)
    .Build();

pub const AchievementManager = interop.ManagedObjectTypeBuilder("app.AchievementManager")
    .Field(._TotalClearPoint, u64, null, null)
    .Build();

pub const InvenotryUser = interop.ManagedObjectTypeBuilder("app.InventoryUser")
    .Field(.User00, interop.ManagedObjectSelf, null, null)
    .Field(.User01, interop.ManagedObjectSelf, null, null)
    .Field(.User02, interop.ManagedObjectSelf, null, null)
    .Field(.User03, interop.ManagedObjectSelf, null, null)
    .Field(.None, interop.ManagedObjectSelf, null, null)
    .Build();

pub const InventoryType = enum(c_int) {
    hand = 0,
    itembox = 1,
    shareitembox = 2,
};

pub const Inventory = interop.ManagedObjectTypeBuilder("app.Inventory")
    .Method(.mergeMoneys, void, null)
    .Param("System.Int32", i32, null)
    .Field(._Moneys, i32, null, null)
    .Build();

pub const InventoryManager = interop.ManagedObjectTypeBuilder("app.InventoryManager")
    .Method(.getInventory, ?Inventory, null)
    .Param("app.InventoryUser", InvenotryUser, null)
    .Param("app.InventoryType", InventoryType, null)
    .Build();
