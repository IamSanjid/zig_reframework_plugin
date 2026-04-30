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

pub const SystemArray = interop.ManagedObject("System.Array", .{
    .GetLength = .{
        .params = .{
            .{ .type_name = "System.Int32", .type = i32 },
        },
        .ret = .{ .type = i32 },
    },
    .GetValue = .{
        .params = .{
            .{ .type_name = "System.Int32", .type = i32 },
        },
        .ret = .{ .type = ?re.api.sdk.ManagedObject },
    },
    .SetValue = .{
        .params = .{
            // The signature becomes only the method name, no param type is included.
            .{ .type_name = null, .type = re.api.sdk.ManagedObject },
            .{ .type_name = "System.Int32", .type = i32 },
        },
        .ret = .{ .type = void },
    },
}, .{});

pub const ItemCategory = re.sdk.ManagedObject;
pub const ItemId = re.sdk.ManagedObject;

pub const InventoryPanelShapeSetting = interop.ManagedObject("app.InventoryPanelShapeSetting", .{}, .{
    ._BaseShapeTypeCache = .{ .type = re.sdk.ManagedObject },
    ._BaseShapeTypeStr = .{ .type = interop.SystemString },
});

pub const InventorySlotCapacitySetting = interop.ManagedObject("app.InventorySlotCapacitySetting", .{}, .{
    ._BaseCapacity = .{ .type = i32 },
    ._BaseItemBoxCapacity = .{ .type = i32 },
    // ._OverwriteCapacityData = .{ .type = SystemArray },
});

pub const ItemDetailData = interop.ManagedObject("app.ItemDetailData", .{}, .{
    ._ItemID = .{ .type = re.sdk.ManagedObject },
    ._ItemCategory = .{ .type = re.sdk.ManagedObject },
    ._NameMessageId = .{ .type = interop.ValueType },
    ._CaptionMessageId = .{ .type = interop.ValueType },
    // app.InventoryPanelShapeSetting
    ._PanelShapeData = .{ .type = re.sdk.ManagedObject },
    // app.InventorySlotCapacitySetting
    ._SlotCapacityData = .{ .type = InventorySlotCapacitySetting },
    ._AttachmentCostCapacity = .{ .type = i32 },
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

pub const PlayerContext = interop.ManagedObject("app.PlayerContext", .{
    .get_InventoryUserID = .{
        .params = .{},
        .ret = .{ .type = InvenotryUser },
    },
}, .{});

pub const CharacterManager = interop.ManagedObject("app.CharacterManager", .{
    .getPlayerContextRef = .{
        .params = .{},
        .ret = .{ .type = ?PlayerContext },
    },
}, .{});
