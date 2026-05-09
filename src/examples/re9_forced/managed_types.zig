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

    pub fn copyFrom(
        item_detail: ItemDetailData,
        arena: std.mem.Allocator,
        scope: *interop.Scope,
        sdk: interop.InteropSdk,
    ) !ItemDetails {
        const item_id = try item_detail.get(._ItemID, scope, .fo(sdk));
        const item_category = try item_detail.get(._ItemCategory, scope, .fo(sdk));

        // Scope arena allocated ValueType, scope resets it when its needed.
        // Interoped from System.Guid to [:0]const u8, we lost the original System.Guid data.
        const name_message_id = try item_detail.get(._NameMessageId, scope, .fo(sdk));
        const caption_message_id = try item_detail.get(._CaptionMessageId, scope, .fo(sdk));

        const name_message_utf8 = if (name_message_id.len == 0)
            try std.fmt.allocPrintSentinel(arena, "UnknownName_0x{x}", .{@intFromPtr(item_category.raw)}, 0)
        else
            try arena.dupeSentinel(u8, name_message_id, 0);

        const caption_message_utf8 = if (caption_message_id.len == 0)
            try std.fmt.allocPrintSentinel(arena, "UnknownCaption_0x{x}", .{@intFromPtr(item_category.raw)}, 0)
        else
            try arena.dupeSentinel(u8, caption_message_id, 0);

        const slot_capacity_data = try item_detail.get(._SlotCapacityData, scope, .fo(sdk));

        return .{
            .id = item_id,
            .category = item_category,
            .name = name_message_utf8,
            .caption = caption_message_utf8,
            .base_capacity = try slot_capacity_data.get(._BaseCapacity, scope, .fo(sdk)),
            .base_item_box_capacity = try slot_capacity_data.get(._BaseItemBoxCapacity, scope, .fo(sdk)),
        };
    }
};

pub const PanelItemDetails = struct {
    is_infinite_item: bool,
    is_infinite_loader: bool,
    is_zero_cost_loader: bool,
    is_equipment: bool,
    is_loader: bool,
    is_gun: bool,
    detail_data: ItemDetails,
    stock: i32,
    stock_capacity: i32,
    attachment_cost_capacity: i32,
    attached_cost: i32,
    panel_state: ?re.sdk.ManagedObject,
    key: InventoryPanelKey,
    inventory_key: re.sdk.ManagedObject,
    loading_type: ItemLoadingType,

    pub fn copyFrom(
        panel_item_info: InventoryPanelItemInfo,
        arena: std.mem.Allocator,
        scope: *interop.Scope,
        sdk: interop.InteropSdk,
    ) !PanelItemDetails {
        const detail_data = try panel_item_info.get(._DetailData, scope, .fo(sdk));
        const item_details = try ItemDetails.copyFrom(detail_data, arena, scope, sdk);

        return .{
            .is_infinite_item = try panel_item_info.get(._IsInfiniteItem, scope, .fo(sdk)),
            .is_infinite_loader = try panel_item_info.get(._IsInfiniteLoader, scope, .fo(sdk)),
            .is_zero_cost_loader = try panel_item_info.get(._IsZeroCostLoader, scope, .fo(sdk)),
            .is_equipment = try panel_item_info.get(._IsEquipment, scope, .fo(sdk)),
            .is_loader = try panel_item_info.get(._IsLoader, scope, .fo(sdk)),
            .is_gun = try panel_item_info.get(._IsGun, scope, .fo(sdk)),
            .detail_data = item_details,
            .stock = try panel_item_info.get(._Stock, scope, .fo(sdk)),
            .stock_capacity = try panel_item_info.get(._StockCapacity, scope, .fo(sdk)),
            .attachment_cost_capacity = try panel_item_info.get(._AttachmentCostCapacity, scope, .fo(sdk)),
            .attached_cost = try panel_item_info.get(._AttachedCost, scope, .fo(sdk)),
            .panel_state = try panel_item_info.get(._PanelState, scope, .fo(sdk)),
            .key = try panel_item_info.get(._Key, scope, .fo(sdk)),
            .inventory_key = try panel_item_info.get(._InventoryKey, scope, .fo(sdk)),
            .loading_type = try panel_item_info.get(._LoadingType, scope, .fo(sdk)),
        };
    }
};

pub const CurrentObjectiveDetails = struct {
    id: ObjectiveID,
    parent_id: ObjectiveID,
    is_achieved: bool,
    message: [:0]const u8,
    count: i32 = 0,
    max_count: i32 = 0,

    pub fn copyFrom(
        objective_info: CurrentObjectiveInfo,
        arena: std.mem.Allocator,
        scope: *interop.Scope,
        sdk: interop.InteropSdk,
    ) !CurrentObjectiveDetails {
        const id = try objective_info.call(.get_ObjectiveID, scope, .fo(sdk), .{});
        const parent_id = try objective_info.call(.get_ParentID, scope, .fo(sdk), .{});
        const is_achieved = try objective_info.call(.get_IsAchieve, scope, .fo(sdk), .{});
        const message = try objective_info.call(.get_MessageID, scope, .fo(sdk), .{});
        const count = try objective_info.call(.get_Count, scope, .fo(sdk), .{});
        const max_count = try objective_info.call(.get_MaxCount, scope, .fo(sdk), .{});

        const message_utf8 = if (message.len == 0)
            try std.fmt.allocPrintSentinel(arena, "UnknownMessage_0x{x}", .{@intFromPtr(id.raw)}, 0)
        else
            try arena.dupeSentinel(u8, message, 0);

        return .{
            .id = id,
            .parent_id = parent_id,
            .is_achieved = is_achieved,
            .message = message_utf8,
            .count = count,
            .max_count = max_count,
        };
    }
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

pub const SystemArray = interop.SystemArray;

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

pub const InventoryAcquireItemOptions = enum(c_int) {
    none = 0,
    set_equip_auto = 1,
    set_shortcut_auto = 2,
    default = 3,
};

pub const InventoryPanelKey = re.sdk.ManagedObject;

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
    .Field(._PanelState, ?re.sdk.ManagedObject, null, null)
    .Field(._Key, InventoryPanelKey, null, null)
    .Field(._InventoryKey, re.sdk.ManagedObject, null, null)
    .Field(._LoadingType, ItemLoadingType, null, null)
    .Build();

pub const Inventory = interop.ManagedObjectTypeBuilder("app.Inventory")
    .Method(.mergeMoneys, void, null)
    .Param("System.Int32", i32, null)
    .Method(.consumeStock, bool, null)
    .Param("app.Inventory.PanelKey", InventoryPanelKey, null)
    .Param("System.Int32", i32, null)
    .Param("app.ItemStockChangedEventType", ItemStockChangedEventType, null)
    .Method(.removePanel, bool, null)
    .Param("app.Inventory.PanelKey", InventoryPanelKey, null)
    .Param("app.ItemStockChangedEventType", ItemStockChangedEventType, null)
    .Method(.mergeOrAdd, re.sdk.ManagedObject, null)
    .Param("app.ItemID", ItemId, null)
    .Param("System.Int32", i32, null)
    .Param("System.Boolean", bool, null)
    .Param("app.Inventory.AcquireItemOptions", InventoryAcquireItemOptions, null)
    .Param("app.ItemStockChangedEventType", ItemStockChangedEventType, null)
    .Method(.addPreferentialPanel, InventoryPanelKey, null)
    .Param("app.ItemID", ItemId, null)
    .Param("System.Int32", i32, null)
    .Param("app.ItemStockChangedEventType", ItemStockChangedEventType, null)
    .Method(.hasPanel, bool, null)
    .Param("app.Inventory.PanelKey", InventoryPanelKey, null)
    .Field(._Moneys, i32, null, null)
    .Field(._PanelItems, *GenericDictionary, null, null)
    .Build();

pub const ItemStockChangedEventType = interop.ManagedObjectTypeBuilder("app.ItemStockChangedEventType")
    .Field(.Default, interop.ManagedObjectSelf, null, null)
    .Field(.Discard, interop.ManagedObjectSelf, null, null)
    .Field(.Reloaded, interop.ManagedObjectSelf, null, null)
    .Field(.Unloaded, interop.ManagedObjectSelf, null, null)
    .Field(.Switched, interop.ManagedObjectSelf, null, null)
    .Field(.Moved, interop.ManagedObjectSelf, null, null)
    .Field(.Craft, interop.ManagedObjectSelf, null, null)
    .Field(.Backup, interop.ManagedObjectSelf, null, null)
    .Field(.Missable, interop.ManagedObjectSelf, null, null)
    .Field(.Append, interop.ManagedObjectSelf, null, null)
    .Field(.CarryOver, interop.ManagedObjectSelf, null, null)
    .Build();

pub const InventoryManager = interop.ManagedObjectTypeBuilder("app.InventoryManager")
    .Method(.getInventory, ?Inventory, null)
    .Param("app.InventoryUser", InvenotryUser, null)
    .Param("app.InventoryType", InventoryType, null)
    .Method(.pushEvent, void, null)
    .Param("app.InventoryEventArgs", re.sdk.ManagedObject, null)
    .Method(.execEvents, void, null)
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

pub const ObjectiveID = re.sdk.ManagedObject;

pub const ObjectiveData = interop.ManagedObjectTypeBuilder("app.ObjectiveController.ObjectiveData")
    .Field(._ID, ObjectiveID, null, null)
    .Field(._ParentID, ObjectiveID, null, null)
    .Field(._IsAchieved, bool, null, null)
    .Field(._MessageID, [:0]const u8, messageSystemGuidToString, null)
    .Field(._Counter, i32, null, null)
    .Build();

pub const CurrentObjectiveInfo = interop.ManagedObjectTypeBuilder("app.CurrentObjectiveInfo")
    .Method(.get_ObjectiveID, ObjectiveID, null)
    .Method(.get_ParentID, ObjectiveID, null)
    .Method(.get_IsAchieve, bool, null)
    .Method(.get_MessageID, [:0]const u8, messageSystemGuidToString)
    .Method(.get_Count, i32, null)
    .Method(.get_MaxCount, i32, null)
    .Field(.@"<ObjectiveID>k__BackingField", ObjectiveID, null, null)
    .Field(.@"<ParentID>k__BackingField", ObjectiveID, null, null)
    .Field(.@"<IsAchieve>k__BackingField", bool, null, null)
    .Field(.@"<MessageID>k__BackingField", [:0]const u8, messageSystemGuidToString, null)
    .Field(.@"<Count>k__BackingField", i32, null, null)
    .Field(.@"<MaxCount>k__BackingField", i32, null, null)
    .Build();

pub const ObjectiveController = interop.ManagedObjectTypeBuilder("app.ObjectiveController")
    .Method(.getObjectiveInfoArray, SystemArray, null)
    .Method(.getLastObjective, ObjectiveData, null)
    .Build();

pub const ObjectiveManager = interop.ManagedObjectTypeBuilder("app.ObjectiveManager")
    .Method(.requestSetObjective, void, null)
    .Param("app.ObjectiveID", ObjectiveID, null)
    .Param("System.Boolean", bool, null)
    .Method(.requestAchieveObjective, void, null)
    .Param("app.ObjectiveID", ObjectiveID, null)
    .Param("System.Boolean", bool, null)
    .Method(.requestAbandonObjective, void, null)
    .Param("app.ObjectiveID", ObjectiveID, null)
    .Param("System.Boolean", bool, null)
    .Method(.requestCountObjective, void, null)
    .Param("app.ObjectiveID", ObjectiveID, null)
    .Param("System.Boolean", bool, null)
    .Param("System.Boolean", bool, null)
    .Method(.isOpenMap, bool, null)
    .Param("app.ObjectiveID", ObjectiveID, null)
    .Method(.getObjectiveInfoArray, SystemArray, null)
    .Field(._ObjectiveController, ObjectiveController, null, null)
    .Build();

pub const SaveSlotCategory = enum(c_int) {
    undefined = 0,
    system = 1,
    auto = 2,
    game = 3,
    userdefine_system_0 = 4,
    userdefine_system_1 = 5,
    userdefine_game_0 = 6,
    userdefine_game_1 = 7,
    userdefine_game_2 = 8,
    userdefine_game_3 = 9,
};

pub const SaveSlotSelectionMethod = enum(c_int) {
    manual = 0,
    empty = 1,
    latest = 2,
    newest = 4,
    oldest = 8,
    empty_or_latest = 513,
    empty_or_newest = 1025,
    empty_or_oldest = 2049,
    latest_or_empty = 258,
    newest_or_empty = 260,
    oldest_or_empty = 264,
    _,
};

pub const SaveServiceManager = interop.ManagedObjectTypeBuilder("app.SaveServiceManager")
    .Method(.requestSave, bool, null)
    .Param("app.SaveSlotCategory", SaveSlotCategory, null)
    .Param("app.SaveSlotSelectionMethod", SaveSlotSelectionMethod, null)
    .Param("System.Nullable`1<app.SavedataSaveRequestArgs>", ?re.sdk.ManagedObject, null)
    .Build();

pub const SaveSlotCategoryBits = enum(c_int) {
    none = 0,
    system = 2,
    auto = 4,
    game = 8,
    userdefine_system_0 = 16,
    userdefine_system_1 = 32,
    userdefine_game_0 = 64,
    userdefine_game_1 = 128,
    userdefine_game_2 = 256,
    userdefine_game_3 = 512,
};

pub const SceneTransitionManager = interop.ManagedObjectTypeBuilder("app.SceneTransitionManager")
    .Method(.requestTitleSceneJump, void, null)
    .Param("System.Boolean", bool, null)
    .Method(.requestMainGameJump, void, null)
    .Param("System.Boolean", bool, null)
    .Method(.requestMainGameJumpCore, void, null)
    .Param("System.Boolean", bool, null)
    .Param("System.Nullable`1<app.NewgameSetupRequestArgs>", bool, null)
    .Param("app.SaveSlotCategoryBits", SaveSlotCategoryBits, null)
    .Build();

pub const ItemCore = interop.ManagedObjectTypeBuilder("app.ItemCore")
    .Method(.setup, void, null)
    .Param("app.IItemContextInitializer", re.sdk.ManagedObject, null)
    .Method(.onPickup, void, null)
    .Param(null, bool, null)
    .Field(._ItemIDCache, ItemId, null, null)
    .Field(._ItemIDStr, interop.SystemStringView, null, null)
    .Build();

pub const InteractActionItemPickup = interop.ManagedObjectTypeBuilder("app.InteractActionItemPickup")
    .Method(.@".ctor", void, null)
    .Method(.onProcess, void, null)
    .Param("app.InteractTrigger", re.sdk.ManagedObject, null)
    .Field(._ItemCore, ItemCore, null, null)
    .Field(._TargetInventory, Inventory, null, null)
    .Field(._TargetCharaContext, PlayerContext, null, null)
    .Build();

pub const InteractTriggerItemPickupEvent = interop.ManagedObjectTypeBuilder("app.InteractTriggerItemPickupEvent")
    .Method(.@".ctor", void, null)
    .Field(._ItemCore, ItemCore, null, null)
    .Build();

pub const LevelFlowManager = interop.ManagedObjectTypeBuilder("app.LevelFlowManager")
    .Method(.requestGameJump, void, null)
    .Method(.requestStartFlow, void, null)
    .Method(.registerManagedObject, void, null)
    .Param("app.LevelFlowManagedObject", LevelFlowManagedObject, null)
    .Field(._ManagedObjectList, *GenericDictionary, null, null)
    .Build();

pub const LevelFlowManagedObject = interop.ManagedObjectTypeBuilder("app.LevelFlowManagedObject")
    .Method(.get_Enabled, bool, null)
    .Field(._FlowName, NameHash, null, null)
    .Field(._ActiveNo, i32, null, null)
    .Field(._EndNo, i32, null, null)
    .Field(._LevelFlowEndType, LevelFlowEndType, null, null)
    .Field(._ExecutedSave, re.sdk.ManagedObject, null, null)
    .Field(._CollidersList, SystemArray, null, null)
    .Build();

pub const GameObject = interop.ManagedObjectTypeBuilder("via.GameObject")
    .Method(.get_Name, interop.SystemStringView, null)
    .Build();

pub const LevelFlowEndType = enum(c_int) {
    auto = 0,
    none = 1,
    set_no = 2,
};

pub const NameHash = interop.ManagedObjectTypeBuilder("app.NameHash")
    .Field(.EmptyHash, u32, null, null)
    .Field(._Hash, u32, null, null)
    .Build();

pub const LevelProgressID = re.sdk.ManagedObject;

pub const BT_ActionArg = interop.ManagedObjectTypeBuilder("via.behaviortree.ActionArg")
    .Method(.@".ctor", void, null)
    .Build();

pub const LFBTA_FSM_GameJumpAction_LevelFlowGameJumpActionParam = interop.ManagedObjectTypeBuilder("app.LevelFlowBehaviorTreeAction_FSM_GameJumpAction.LevelFlowGameJumpActionParam")
    .Method(.get_ParamArray, SystemArray, null)
    .Build();

pub const LFBTA_FSM_GameJumpAction = interop.ManagedObjectTypeBuilder("app.LevelFlowBehaviorTreeAction_FSM_GameJumpAction")
    .Method(.@".ctor", void, null)
    .Method(.start, void, null)
    .Param("via.behaviortree.ActionArg", BT_ActionArg, null)
    .Field(._IsActionEnd, bool, null, null)
    .Field(._Param, LFBTA_FSM_GameJumpAction_GameJumpData, null, null)
    .Build();

pub const LFBTA_FSM_GameJumpAction_GameJumpData = interop.ManagedObjectTypeBuilder("app.LevelFlowBehaviorTreeAction_FSM_GameJumpAction.GameJumpData")
    .Field(._LevelIDCache, LevelProgressID, null, null)
    .Field(._LevelIDStr, interop.SystemStringView, null, null)
    .Field(._IsOverride, bool, null, null)
    .Field(._JumpName, interop.SystemStringView, null, null)
    .Build();
