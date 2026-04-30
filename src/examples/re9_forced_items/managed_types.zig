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
    std.debug.assert(@offsetOf(GenericDictionary, "_bucket") == re.sdk.ManagedObject.runtime_size + 0x00);
    std.debug.assert(@offsetOf(GenericDictionary, "_entries") == re.sdk.ManagedObject.runtime_size + 0x08);
    std.debug.assert(@offsetOf(GenericDictionary, "_version") == re.sdk.ManagedObject.runtime_size + 0x28);
    std.debug.assert(@offsetOf(GenericDictionary, "_count") == re.sdk.ManagedObject.runtime_size + 0x2c);
}

pub const ConcurrentCatalogDictionary = extern struct {
    _obj_padding: [re.sdk.ManagedObject.runtime_size]u8 align(@alignOf(*anyopaque)),
    _Dict: *GenericDictionary,
};

comptime {
    std.debug.assert(@offsetOf(ConcurrentCatalogDictionary, "_Dict") == re.sdk.ManagedObject.runtime_size + 0x0);
}

pub const ItemManager = extern struct {
    _obj_padding: [re.sdk.ManagedObject.runtime_size]u8 align(@alignOf(*anyopaque)),
    _padding1: [0xe0]u8 align(@alignOf(*anyopaque)),
    _ItemCatalog: *ConcurrentCatalogDictionary,
};

comptime {
    std.debug.assert(@offsetOf(ItemManager, "_ItemCatalog") == re.sdk.ManagedObject.runtime_size + 0xe0);
}

pub fn SystemArray(comptime T: type) type {
    return interop.ManagedObject("System.Array", .{
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
            .ret = .{ .type = ?T },
        },
        .SetValue = .{
            .params = .{
                // The signature becomes only the method name, no param type is included.
                .{ .type_name = null, .type = T },
                .{ .type_name = "System.Int32", .type = i32 },
            },
            .ret = .{ .type = void },
        },
    }, .{});
}

pub const SystemGuid = interop.ValueType;

pub const ItemCategory = re.sdk.ManagedObject;
pub const ItemId = re.sdk.ManagedObject;

pub const InventoryPanelShapeSetting = interop.ManagedObject("app.InventoryPanelShapeSetting", .{}, .{
    ._BaseShapeTypeCache = .{ .type = re.sdk.ManagedObject },
    ._BaseShapeTypeStr = .{ .type = interop.SystemStringView },
});

pub const InventorySlotCapacitySetting = interop.ManagedObject("app.InventorySlotCapacitySetting", .{}, .{
    ._BaseCapacity = .{ .type = i32 },
    ._BaseItemBoxCapacity = .{ .type = i32 },
    // ._OverwriteCapacityData = .{ .type = SystemArray },
});

pub const ItemDetailData = interop.ManagedObject("app.ItemDetailData", .{}, .{
    ._ItemID = .{ .type = ItemId },
    ._ItemCategory = .{ .type = ItemCategory },
    ._NameMessageId = .{ .type = SystemGuid },
    ._CaptionMessageId = .{ .type = SystemGuid },
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
