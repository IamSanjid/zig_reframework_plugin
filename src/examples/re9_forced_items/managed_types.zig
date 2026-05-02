const std = @import("std");

const re = @import("reframework");
const interop = re.interop;

pub const ItemDetails = struct {
    id: re.sdk.ManagedObject,
    category: re.sdk.ManagedObject,
    name: [:0]const u8,
    caption: [:0]const u8,
    base_item_box_capacity: i32,
    base_capacity: i32,
};

// Demostration on how to directly coerce to re-engine il2cpp objects and zig-land.

pub const GenericDictionary = extern struct {
    _obj_padding: [re.sdk.ManagedObject.runtime_size]u8 align(@alignOf(*anyopaque)),
    _bucket: ?*anyopaque,
    _entries: re.sdk.ManagedObject,
    _fastModMultiplier: u64,
    _comparer: ?*anyopaque,
    _freeList: i32,
    _freeCount: i32,
    _version: i32,
    _count: i32,
};

comptime {
    std.debug.assert(@offsetOf(GenericDictionary, "_bucket") == 0x10);
    std.debug.assert(@offsetOf(GenericDictionary, "_entries") == 0x18);
    std.debug.assert(@offsetOf(GenericDictionary, "_version") == 0x38);
    std.debug.assert(@offsetOf(GenericDictionary, "_count") == 0x3c);
}

pub const ConcurrentCatalogDictionary = extern struct {
    _obj_padding: [re.sdk.ManagedObject.runtime_size]u8 align(@alignOf(*anyopaque)),
    _Dict: *GenericDictionary,
};

comptime {
    std.debug.assert(@offsetOf(ConcurrentCatalogDictionary, "_Dict") == 0x10);
}

pub const ItemManager = extern struct {
    _obj_padding: [re.sdk.ManagedObject.runtime_size]u8 align(@alignOf(*anyopaque)),
    _padding1: [0xe0]u8 align(@alignOf(*anyopaque)),
    _ItemCatalog: *ConcurrentCatalogDictionary,
};

comptime {
    std.debug.assert(@offsetOf(ItemManager, "_ItemCatalog") == 0xf0);
}

pub const SystemArray = interop.ManagedObjectTypeBuilder("System.Array")
    .Method(.GetLength, i32, null)
    .Param("System.Int32", i32, null)
    .MethodWithName("GetValue", .GetValue, ?re.api.sdk.ManagedObject, null)
    .Param("System.Int32", i32, null)
    .Method(.SetValue, void, null)
    .Param(null, re.api.sdk.ManagedObject, null)
    .Param("System.Int32", i32, null)
    .Build();

pub const SystemGuid = interop.ValueType;

pub const ItemCategory = re.sdk.ManagedObject;
pub const ItemId = re.sdk.ManagedObject;

pub const InventoryPanelShapeSetting = interop.ManagedObjectTypeBuilder("app.InventoryPanelShapeSetting")
    .Field(._BaseShapeTypeCache, re.sdk.ManagedObject, null, null)
    .Field(._BaseShapeTypeStr, interop.SystemStringView, null, null)
    .Build();

pub const InventorySlotCapacitySetting = interop.ManagedObjectTypeBuilder("app.InventorySlotCapacitySetting")
    .Field(._BaseCapacity, i32, null, null)
    .Field(._BaseItemBoxCapacity, i32, null, null)
    // .Field(._OverwriteCapacityData, SystemArray, null, null)
    .Build();

fn messageSystemGuidToString(
    sdk_ptr: *const anyopaque,
    scope: *interop.Scope,
    from_type_def: re.sdk.TypeDefinition,
    data: *?*anyopaque,
) anyerror![:0]const u8 {
    var name_buf: [256]u8 = undefined;
    const sdk: *const interop.InteropSdk = @ptrCast(@alignCast(sdk_ptr));
    const tdb = re.sdk.getTdb(.fo(sdk)) orelse return error.GetTdbFailed;

    if (from_type_def.getVmObjType(.fo(sdk)) != .valtype) {
        return error.ExpectedValueType;
    }
    if (!std.mem.eql(u8, try from_type_def.getFullName(.fo(sdk), &name_buf), "System.Guid")) {
        return error.ExpectedSystemGuid;
    }
    const arena = scope.arena.allocator();
    const message_id = try interop.ValueType.init(arena, .fo(sdk), data, from_type_def);
    const GuiMessageT = try scope.cache.resolve("via.gui.message", tdb, .fo(sdk));
    const message = try GuiMessageT.scoped(scope).callStaticMethod(
        "get(System.Guid)",
        interop.SystemStringView,
        .fo(sdk),
        .{message_id},
    );
    return std.unicode.utf16LeToUtf8AllocZ(arena, message.data);
}

pub const ItemDetailData = interop.ManagedObjectTypeBuilder("app.ItemDetailData")
    .Field(._ItemID, ItemId, null, null)
    .Field(._ItemCategory, ItemCategory, null, null)
    // We won't be able to set, it will create a managed string and point to that
    // newly created string but it's expected to be a System.Guid, game will crash.
    // But we don't care about setting it anyways we just want the in-game info.
    .Field(._NameMessageId, [:0]const u8, messageSystemGuidToString, null)
    .Field(._CaptionMessageId, [:0]const u8, messageSystemGuidToString, null)
    // app.InventoryPanelShapeSetting
    .Field(._PanelShapeData, re.sdk.ManagedObject, null, null)
    .Field(._SlotCapacityData, InventorySlotCapacitySetting, null, null)
    .Field(._AttachmentCostCapacity, i32, null, null)
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

pub const ItemLoadingType = enum(c_int) {
    none = 0,
    type_a = 1,
    type_b = 2,
};

pub const InventoryPanelItemInfo = interop.ManagedObjectTypeBuilder("app.Inventory.PanelItemInfo")
    .Field(._IsInfiniteItem, bool, null, null)
    .Field(._IsInfiniteLoader, bool, null, null)
    .Field(._IsZeroCostLoader, bool, null, null)
    .Field(._IsEquipment, bool, null, null)
    .Field(._IsLoader, bool, null, null)
    .Field(._IsGun, bool, null, null)
    .Field(._DetailData, ItemDetailData, null, null)
    .Field(._Stock, i32, null, null)
    .Field(._StockCapacity, i32, null, null)
    .Field(._AttachmentCostCapacity, i32, null, null)
    .Field(._AttachedCost, i32, null, null)
    .Field(._PanelState, re.sdk.ManagedObject, null, null)
    .Field(._LoadingType, ItemLoadingType, null, null)
    .Build();

pub const Inventory = interop.ManagedObjectTypeBuilder("app.Inventory")
    .Method(.mergeMoneys, void, null)
    .Param("System.Int32", i32, null)
    .Field(._Moneys, i32, null, null)
    .Field(._PanelItems, *GenericDictionary, null, null)
    .Build();

pub const InventoryManager = interop.ManagedObjectTypeBuilder("app.InventoryManager")
    .Method(.getInventory, ?Inventory, null)
    .Param("app.InventoryUser", InvenotryUser, null)
    .Param("app.InventoryType", InventoryType, null)
    .Build();

pub const PlayerContext = interop.ManagedObjectTypeBuilder("app.PlayerContext")
    .Method(.get_InventoryUserID, InvenotryUser, null)
    .Method(.onUnlinked, void, null)
    .Build();

pub const CharacterManager = interop.ManagedObjectTypeBuilder("app.CharacterManager")
    .Method(.getPlayerContextRef, ?PlayerContext, null)
    .Method(.notifyPlayerInitialized, void, null)
    .Method(.updateInveontoryForPlayer, void, null)
    .Build();
