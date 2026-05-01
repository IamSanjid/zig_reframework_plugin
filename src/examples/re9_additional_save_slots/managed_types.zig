const re = @import("reframework");

const interop = re.interop;

pub const SystemArray = interop.ManagedObjectTypeBuilder("System.Array")
    .Method(.GetLength, i32, null)
    .Param("System.Int32", i32, null)
    // Previous method gets added to "Type Builder".
    .MethodWithName("GetValue", .GetValue, ?re.api.sdk.ManagedObject, null)
    .Param("System.Int32", i32, null)
    // Previous method gets added to "Type Builder".
    .Method(.SetValue, void, null)
    // type name as null means the param type is not included in the method signature,
    // so only the method name is used for method resolution.
    .Param(null, re.api.sdk.ManagedObject, null)
    .Param("System.Int32", i32, null)
    .Build(); // Type built, not the method.

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

pub const SaveSlotPartition = interop.ManagedObjectTypeBuilder("app.SaveSlotPartition")
    .Field(._Usage, SaveSlotCategory, null, null)
    .Field(._HeadSlotId, i32, null, null)
    .Field(._SlotCount, i32, null, null)
    .Build();

pub const GuiSaveLoadControllerUnit = interop.ManagedObjectTypeBuilder("app.GuiSaveLoadController.Unit")
    .Field(._SaveItemNum, i32, null, null)
    .Build();

pub const GuiSaveDataInfo = interop.ManagedObjectTypeBuilder("app.GuiSaveDataInfo").Build();
pub const GuiSaveLoadModel = interop.ManagedObjectTypeBuilder("app.GuiSaveLoadModel")
    .Method(.makeSaveData, ?GuiSaveDataInfo, null)
    .Param("app.SaveSlotCategory", SaveSlotCategory, null)
    .Param("System.Int32", i32, null)
    .Build(); // Type built, not the method.
