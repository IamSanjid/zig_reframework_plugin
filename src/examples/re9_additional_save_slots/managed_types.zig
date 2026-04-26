const re = @import("reframework");

const interop = re.interop;

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

pub const SaveSlotSegmentType = enum(c_int) {
    invalid = 0,
    default_0 = 1,
};

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

pub const SaveSlotPartition = interop.ManagedObject("app.SaveSlotPartition", .{}, .{
    ._Usage = .{ .type = SaveSlotCategory },
    ._HeadSlotId = .{ .type = i32 },
    ._SlotCount = .{ .type = i32 },
});

pub const GuiSaveLoadControllerUnit = interop.ManagedObject("app.GuiSaveLoadController.Unit", .{}, .{
    ._SaveItemNum = .{ .type = i32 },
});

pub const GuiSaveDataInfo = interop.ManagedObject("app.GuiSaveDataInfo", .{}, .{});
pub const GuiSaveLoadModel = interop.ManagedObject("app.GuiSaveLoadModel", .{
    .makeSaveData = .{
        .params = .{
            .{ .type_name = "app.SaveSlotCategory", .type = SaveSlotCategory },
            .{ .type_name = "System.Int32", .type = i32 },
        },
        .ret = .{ .type = ?GuiSaveDataInfo },
    },
}, .{});
