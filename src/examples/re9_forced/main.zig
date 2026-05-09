const std = @import("std");

const re = @import("reframework");

const win32 = @import("win32");
const cimgui = @import("cimgui");

const managed_types = @import("managed_types.zig");
const ui = @import("ui.zig");

const windows = std.os.windows;

const interop = re.interop;

const SystemArray = managed_types.SystemArray;
const ItemDetails = managed_types.ItemDetails;
const PanelItemDetails = managed_types.PanelItemDetails;
const ItemDetailData = managed_types.ItemDetailData;
const ItemCategory = managed_types.ItemCategory;
const ItemId = managed_types.ItemId;
const PlayerContext = managed_types.PlayerContext;
const Inventory = managed_types.Inventory;
const InventoryType = managed_types.InventoryType;
const InventoryAcquireItemOptions = managed_types.InventoryAcquireItemOptions;
const InventoryPanelKey = managed_types.InventoryPanelKey;
const InventoryPanelItemInfo = managed_types.InventoryPanelItemInfo;
const ItemStockChangedEventType = managed_types.ItemStockChangedEventType;
const CurrentObjectiveDetails = managed_types.CurrentObjectiveDetails;
const CurrentObjectiveInfo = managed_types.CurrentObjectiveInfo;
const ObjectiveID = managed_types.ObjectiveID;
const ItemCore = managed_types.ItemCore;
const InteractActionItemPickup = managed_types.InteractActionItemPickup;
const LevelFlowManagedObject = managed_types.LevelFlowManagedObject;
const GameObject = managed_types.GameObject;
const LevelProgressID = managed_types.LevelProgressID;
const BT_ActionArg = managed_types.BT_ActionArg;
const LFBTA_FSM_GameJumpAction = managed_types.LFBTA_FSM_GameJumpAction;
const LFBTA_FSM_GameJumpAction_GameJumpData = managed_types.LFBTA_FSM_GameJumpAction_GameJumpData;

const CharacterManager = managed_types.CharacterManager;
const InventoryManager = managed_types.InventoryManager;
const ObjectiveManager = managed_types.ObjectiveManager;
const SaveServiceManager = managed_types.SaveServiceManager;
const SceneTransitionManager = managed_types.SceneTransitionManager;
const LevelFlowManager = managed_types.LevelFlowManager;

const GenericDictionary = managed_types.GenericDictionary;
const ConcurrentCatalogDictionary = managed_types.ConcurrentCatalogDictionary;
const ItemManager = managed_types.ItemManager;

pub fn pluginLog(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const log_msg = std.fmt.allocPrintSentinel(
        g.allocator,
        (if (scope != .default) ("(" ++ @tagName(scope) ++ "): ") else "") ++ format,
        args,
        0,
    ) catch return;
    defer g.allocator.free(log_msg);
    switch (message_level) {
        .err => g.api.logError("%s", .{log_msg.ptr}),
        .warn => g.api.logWarn("%s", .{log_msg.ptr}),
        else => g.api.logInfo("%s", .{log_msg.ptr}),
    }
}

pub const std_options: std.Options = .{
    .logFn = pluginLog,
};

const log = std.log.scoped(.re9_forced);

const verified_sdk_spec = re.api.specs.extend(
    re.api.specs.minimal.sdk,
    .{ .field = .{ .extend = .{.get_name} } },
);

pub const g = struct {
    pub var allocator: std.mem.Allocator = undefined;
    pub var io: std.Io = undefined;
    pub var interop_cache: re.interop.ManagedTypeCache = undefined;
    pub var api: re.api.Api = undefined;
    pub var sdk: re.api.VerifiedSdk(verified_sdk_spec) = undefined;
    pub var tdb: re.sdk.Tdb = undefined;

    pub var character_manager: CharacterManager = undefined;
    pub var inventory_manager: InventoryManager = undefined;
    pub var objective_manager: ObjectiveManager = undefined;
    pub var save_sevice_manager: SaveServiceManager = undefined;
    pub var scene_transition_manager: SceneTransitionManager = undefined;
    pub var level_flow_manager: LevelFlowManager = undefined;

    pub var items: Items = undefined;
    pub var level_flow_managed_objects: LevelFlowManagedObjects = undefined;
    pub var item_pickups: ItemPickups = undefined;
    pub var player: ?Player = null;

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    var threaded: std.Io.Threaded = undefined;

    fn init(init_api: re.Api) !void {
        api = init_api;
        sdk = try api.verifiedSdk(verified_sdk_spec);
        tdb = re.sdk.getTdb(.fo(g.sdk)) orelse return error.TdbNotFound;

        const item_mgr_mo = re.sdk.getManagedSingleton(.fo(g.sdk), "app.ItemManager") orelse return error.ItemManagerNotFound;
        items = .init(@ptrCast(@alignCast(item_mgr_mo.raw)));

        item_pickups = .{ .arena = .init(allocator) };

        level_flow_managed_objects = .{ .arena = .init(allocator) };

        character_manager = try CharacterManager.init(
            &g.interop_cache,
            .fo(g.sdk),
            re.sdk.getManagedSingleton(.fo(g.sdk), CharacterManager.fullTypeName()) orelse
                return error.CharacterManagerNotFound,
        );
        inventory_manager = try InventoryManager.init(
            &g.interop_cache,
            .fo(g.sdk),
            re.sdk.getManagedSingleton(.fo(g.sdk), InventoryManager.fullTypeName()) orelse
                return error.InventoryManagerNotFound,
        );
        objective_manager = try ObjectiveManager.init(
            &g.interop_cache,
            .fo(g.sdk),
            re.sdk.getManagedSingleton(.fo(g.sdk), ObjectiveManager.fullTypeName()) orelse
                return error.ObjectiveManagerNotFound,
        );
        save_sevice_manager = try SaveServiceManager.init(
            &g.interop_cache,
            .fo(g.sdk),
            re.sdk.getManagedSingleton(.fo(g.sdk), SaveServiceManager.fullTypeName()) orelse
                return error.SaveServiceManagerNotFound,
        );
        scene_transition_manager = try SceneTransitionManager.init(
            &g.interop_cache,
            .fo(g.sdk),
            re.sdk.getManagedSingleton(.fo(g.sdk), SceneTransitionManager.fullTypeName()) orelse
                return error.SceneTransitionManagerNotFound,
        );
        level_flow_manager = try LevelFlowManager.init(
            &g.interop_cache,
            .fo(g.sdk),
            re.sdk.getManagedSingleton(.fo(g.sdk), LevelFlowManager.fullTypeName()) orelse
                return error.LevelFlowManagerNotFound,
        );
    }

    fn attach() void {
        threaded = .init(debug_allocator.allocator(), .{});
        allocator = debug_allocator.allocator();
        io = threaded.io();
        interop_cache = .init(debug_allocator.allocator(), io);
    }

    fn reset() void {
        interop_cache.deinit();

        threaded.deinit();
        _ = debug_allocator.detectLeaks();
        _ = debug_allocator.deinit();
    }

    pub inline fn errorInSafeMode(cond: bool, err: anytype) !void {
        const mode = @import("builtin").mode;
        if (comptime mode == .Debug or mode == .ReleaseSafe) {
            if (!cond) {
                return err;
            }
        }
    }

    pub fn triggerAutoSave() !void {
        const ArgsT = try interop_cache.resolve("app.SavedataSaveRequestArgs", tdb, .fo(sdk));
        const NullableT = try interop_cache.resolve("System.Nullable`1<app.SavedataSaveRequestArgs>", tdb, .fo(sdk));
        var scope = interop_cache.newScope(allocator);
        defer scope.deinit();

        const default_args = try ArgsT.scoped(&scope).getStatic(.Default, interop.ValueType, .fo(sdk));

        const nullable_args = try interop.ValueType.create(
            scope.arena.allocator(),
            .fo(sdk),
            NullableT.type_def_metadata.def,
        );
        try NullableT.scoped(&scope).call(nullable_args, ".ctor(app.SavedataSaveRequestArgs)", void, .fo(sdk), .{default_args});

        _ = try save_sevice_manager.call(.requestSave, &scope, .fo(g.sdk), .{
            managed_types.SaveSlotCategory.auto,
            managed_types.SaveSlotSelectionMethod.newest_or_empty,
            nullable_args,
        });
    }

    pub fn triggerManualSave(selection_method: managed_types.SaveSlotSelectionMethod) !void {
        // TODO: let user choose any save slot.
        if (selection_method == .manual) {
            return error.ManualSaveSlotSelectionNotSupported;
        }
        const ArgsT = try interop_cache.resolve("app.SavedataSaveRequestArgs", tdb, .fo(sdk));
        const NullableT = try interop_cache.resolve("System.Nullable`1<app.SavedataSaveRequestArgs>", tdb, .fo(sdk));
        var scope = interop_cache.newScope(allocator);
        defer scope.deinit();

        const default_args = try ArgsT.scoped(&scope).getStatic(.Default, interop.ValueType, .fo(sdk));

        const nullable_args = try interop.ValueType.create(
            scope.arena.allocator(),
            .fo(sdk),
            NullableT.type_def_metadata.def,
        );
        try NullableT.scoped(&scope).call(nullable_args, ".ctor(app.SavedataSaveRequestArgs)", void, .fo(sdk), .{default_args});

        _ = try save_sevice_manager.call(.requestSave, &scope, .fo(g.sdk), .{
            managed_types.SaveSlotCategory.game,
            selection_method,
            nullable_args,
        });
    }

    pub inline fn performPickup(item_id: ItemId) !void {
        var scope = interop_cache.newScope(allocator);
        defer scope.deinit();

        const pickups = item_pickups.map.get(item_id) orelse return error.PickupNotFound;
        const pickup = pickups.getLast() orelse return;

        const item_core = pickup.get(._ItemCore, &scope, .fo(g.sdk)) catch return;

        const evt = try managed_types.InteractTriggerItemPickupEvent.createInstance(
            &g.interop_cache,
            .fo(g.sdk),
            .none,
        );
        evt.managed.addRef(.fo(g.sdk));
        try evt.call(.@".ctor", &scope, .fo(g.sdk), .{});
        try evt.set(._ItemCore, &scope, .fo(g.sdk), item_core);
        return pickup.call(.onProcess, &scope, .fo(g.sdk), .{evt.managed});
    }
};

pub const Items = struct {
    manager: *ItemManager,
    arena: std.heap.ArenaAllocator,
    categories: std.AutoHashMapUnmanaged(ItemCategory, [:0]const u8) = .empty,
    items_cache: Cache = .empty,
    last_version: i32 = 0,

    const Cache = std.AutoHashMapUnmanaged(ItemId, ItemDetails);

    pub const IteratorEntries = struct {
        owner: *Items,
        scope: *interop.Scope,
        entries: interop.SystemArrayEntries,
        next_idx: u32 = 0,

        pub fn next(self: *IteratorEntries) !?ItemDetails {
            @setRuntimeSafety(false);
            if (self.next_idx >= self.entries.len) return null;

            const element_size = self.entries.contained_type_def.getValueTypeSize(.fo(g.sdk));

            while (self.next_idx < self.entries.len) {
                defer self.next_idx += 1;

                const entry_ptr_usize = @intFromPtr(self.entries.ptr) + (self.next_idx * element_size);

                const id = self.scope.getFieldFromTypeDef(
                    @ptrFromInt(entry_ptr_usize),
                    self.entries.contained_type_def,
                    "key",
                    ItemId,
                    null,
                    false,
                    .fo(g.sdk),
                ) catch continue;

                const arena = self.owner.arena.allocator();

                const item_entry = self.owner.items_cache.getOrPut(arena, id) catch continue;
                if (item_entry.found_existing) {
                    return item_entry.value_ptr.*;
                } else {
                    const details_res = blk: {
                        const kvp = self.scope.getFieldFromTypeDef(
                            @ptrFromInt(entry_ptr_usize),
                            self.entries.contained_type_def,
                            "value",
                            re.sdk.ManagedObject,
                            null,
                            false,
                            .fo(g.sdk),
                        ) catch |e| break :blk e;
                        const item_detail = self.scope.getField(kvp, "_Value", ItemDetailData, .fo(g.sdk)) catch |e| break :blk e;
                        const details = ItemDetails.copyFrom(item_detail, arena, self.scope, .fo(g.sdk)) catch |e| {
                            log.err("Failed to copy: {}, context: {s}", .{ e, try g.interop_cache.ownDiagnostics() });
                            break :blk e;
                        };
                        break :blk details;
                    };
                    const details = details_res catch {
                        self.owner.items_cache.removeByPtr(item_entry.key_ptr);
                        continue;
                    };
                    item_entry.value_ptr.* = details;
                    return details;
                }
            }

            return null;
        }
    };

    pub const IteratorCache = struct {
        cache_iter: Cache.ValueIterator,

        pub fn next(self: *IteratorCache) ?ItemDetails {
            const entry = self.cache_iter.next() orelse return null;
            return entry.*;
        }
    };

    pub const Iterator = union(enum) {
        entries: IteratorEntries,
        cache: IteratorCache,

        pub fn next(self: *Iterator) !?ItemDetails {
            switch (self.*) {
                .entries => return self.entries.next(),
                .cache => return self.cache.next(),
            }
        }
    };

    pub const CategoriesIterator = struct {
        iter: std.AutoHashMap(ItemCategory, [:0]const u8).Iterator,

        pub fn next(self: *CategoriesIterator) ?struct {
            category: ItemCategory,
            name: [:0]const u8,
        } {
            const entry = self.iter.next() orelse return null;
            return .{
                .category = entry.key_ptr.*,
                .name = entry.value_ptr.*,
            };
        }
    };

    fn init(manager: *ItemManager) Items {
        return Items{
            .manager = manager,
            .arena = .init(g.allocator),
        };
    }

    fn deinit(self: *Items) void {
        self.arena.deinit();
    }

    fn reset(self: *Items) void {
        self.last_version = 0;
        self.categories = .empty;
        self.items_cache = .empty;
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn repopulate(self: *Items) !void {
        self.reset();
        try self.populateItemCategories();
    }

    fn populateItemCategories(self: *Items) !void {
        const ItemCategoryT = try g.interop_cache.resolve("app.ItemCategory", g.tdb, .fo(g.sdk));
        var scope = g.interop_cache.newScope(g.allocator);
        defer scope.deinit();

        const item_category_typedef = ItemCategoryT.type_def_metadata.def;
        const arena = self.arena.allocator();
        {
            const fields_len = item_category_typedef.getNumFields(.fo(g.sdk));
            var item_category_fields = try std.ArrayList(re.sdk.Field).initCapacity(arena, fields_len);
            defer item_category_fields.deinit(arena);

            const item_category_fields_slice = item_category_fields.addManyAsSliceBounded(fields_len) catch unreachable;
            const fields = try item_category_typedef.getFields(.fo(g.sdk), item_category_fields_slice);

            for (fields) |field| {
                const field_type = field.getType(.fo(g.sdk)) orelse continue;
                if (!field.isStatic(.fo(g.sdk)) or field_type.raw != item_category_typedef.raw) continue;

                const name = field.getName(.fo(g.sdk)) orelse continue;
                const field_value = interop.defaultToZigInterop(re.sdk.ManagedObject)(
                    @constCast(&g.sdk),
                    &scope,
                    field_type,
                    @ptrCast(@alignCast(field.getDataRaw(.fo(g.sdk), null, false) orelse continue)),
                ) catch continue;

                try self.categories.put(arena, field_value, name);
            }
        }

        log.debug("ItemCategories: {}", .{self.categories.count()});
    }

    pub fn iterator(self: *Items, scope: *interop.Scope) !Iterator {
        const item_catalog: *ConcurrentCatalogDictionary = self.manager._ItemCatalog;

        const dict = item_catalog._Dict;

        const version = dict._version;
        if (self.last_version != version or self.items_cache.size == 0) {
            @branchHint(.cold);
            try self.repopulate();

            self.last_version = version;

            const entries = interop.SystemArrayEntries.unsafe(dict._entries, .fo(g.sdk));
            if (entries.contained_type_def.getVmObjType(.fo(g.sdk)) != .valtype) {
                return error.UnexpectedContainedType;
            }

            return .{
                .entries = .{
                    .owner = self,
                    .scope = scope,
                    .entries = entries,
                },
            };
        }

        return .{
            .cache = .{
                .cache_iter = self.items_cache.valueIterator(),
            },
        };
    }

    pub fn categoriesIterator(self: *const Items) CategoriesIterator {
        return .{
            .iter = self.categories.iterator(),
        };
    }
};

pub const ItemPickups = struct {
    collection: std.ArrayList(InteractActionItemPickup) = .empty,
    map: std.AutoHashMapUnmanaged(ItemId, std.ArrayList(InteractActionItemPickup)) = .empty,
    arena: std.heap.ArenaAllocator,

    inline fn collect(self: *ItemPickups, pickup: InteractActionItemPickup) !void {
        const arena = self.arena.allocator();
        return self.collection.append(arena, pickup);
    }

    fn removeItem(self: *ItemPickups, item_core: ItemCore) void {
        var scope = g.interop_cache.newScope(g.allocator);
        defer scope.deinit();

        const id = item_core.get(._ItemIDCache, &scope, .fo(g.sdk)) catch return;
        const pickups_entry = self.map.getEntry(id) orelse return;

        const pickups = pickups_entry.value_ptr;

        for (pickups.items, 0..) |pickup, i| {
            const pickup_item_core = pickup.get(._ItemCore, &scope, .fo(g.sdk)) catch continue;
            if (pickup_item_core.managed.raw == item_core.managed.raw) {
                _ = pickups.swapRemove(i);
                break;
            }
        }

        if (pickups.items.len == 0) {
            self.map.removeByPtr(pickups_entry.key_ptr);
        }
    }

    fn mapPickupsWithItemId(self: *ItemPickups) !void {
        var scope = g.interop_cache.newScope(g.allocator);
        defer scope.deinit();

        const arena = self.arena.allocator();
        for (self.collection.items) |pickup| {
            const item_core = pickup.get(._ItemCore, &scope, .fo(g.sdk)) catch continue;
            const id = item_core.get(._ItemIDCache, &scope, .fo(g.sdk)) catch continue;

            const entry = try self.map.getOrPutValue(arena, id, .empty);
            try entry.value_ptr.append(arena, pickup);
        }

        self.collection.clearRetainingCapacity();
    }

    fn reset(self: *ItemPickups) void {
        _ = self.arena.reset(.retain_capacity);
        self.collection = .empty;
        self.map = .empty;
    }
};

fn Arena(comptime scope: @EnumLiteral()) *std.heap.ArenaAllocator {
    const ArenaCache = struct {
        pub const _scope = @tagName(scope);
        var arena: ?std.heap.ArenaAllocator = undefined;
    };
    if (ArenaCache.arena == null) {
        ArenaCache.arena = .init(g.allocator);
    }
    return &ArenaCache.arena.?;
}

pub const InvenotryManagement = struct {
    items: std.ArrayList(PanelItemDetails) = .empty,
    inventory: ?Inventory = null,

    fn update(self: *InvenotryManagement, arena: std.mem.Allocator, inventory: Inventory, scope: *interop.Scope) !void {
        self.items = .empty;
        self.inventory = inventory;

        const panel_items = try inventory.get(._PanelItems, scope, .fo(g.sdk));

        var entries = interop.SystemArrayEntries.unsafe(panel_items._entries, .fo(g.sdk));
        if (entries.contained_type_def.getVmObjType(.fo(g.sdk)) != .valtype) {
            return error.UnexpectedContainedType;
        }
        try self.items.ensureTotalCapacity(arena, entries.len);

        const element_size = entries.contained_type_def.getValueTypeSize(.fo(g.sdk));

        for (0..entries.len) |idx| {
            const entry_ptr_usize = @intFromPtr(entries.ptr) + (idx * element_size);

            const panel_item_info_opt = try scope.getFieldFromTypeDef(
                @ptrFromInt(entry_ptr_usize),
                entries.contained_type_def,
                "value",
                ?InventoryPanelItemInfo,
                null,
                false,
                .fo(g.sdk),
            );
            const panel_item_info = panel_item_info_opt orelse continue;

            const details = PanelItemDetails.copyFrom(panel_item_info, arena, scope, .fo(g.sdk)) catch |e| {
                log.err("Failed to copy: {}, context: {s}", .{ e, try g.interop_cache.ownDiagnostics() });
                continue;
            };
            try self.items.append(arena, details);
        }
    }

    pub inline fn itemsSlice(self: InvenotryManagement) []const PanelItemDetails {
        return self.items.items;
    }

    pub inline fn containsItemId(self: InvenotryManagement, item_id: ItemId) bool {
        for (self.items.items) |item| {
            if (item.detail_data.id.raw == item_id.raw) {
                return true;
            }
        }
        return false;
    }

    pub inline fn consumeStock(
        self: InvenotryManagement,
        scope: *interop.Scope,
        panel_key: InventoryPanelKey,
        amount: i32,
        event_type: ItemStockChangedEventType,
    ) !bool {
        const inventory = self.inventory orelse return error.InventoryNotSet;
        const res = try inventory.call(
            .consumeStock,
            scope,
            .fo(g.sdk),
            .{ panel_key, amount, event_type },
        );
        try g.character_manager.call(.updateInveontoryForPlayer, scope, .fo(g.sdk), .{});
        return res;
    }

    pub inline fn removePanel(
        self: InvenotryManagement,
        scope: *interop.Scope,
        panel_key: InventoryPanelKey,
        event_type: ItemStockChangedEventType,
    ) !bool {
        const inventory = self.inventory orelse return error.InventoryNotSet;
        const res = try inventory.call(
            .removePanel,
            scope,
            .fo(g.sdk),
            .{ panel_key, event_type },
        );
        try g.character_manager.call(.updateInveontoryForPlayer, scope, .fo(g.sdk), .{});
        return res;
    }

    pub inline fn mergeOrAdd(
        self: InvenotryManagement,
        scope: *interop.Scope,
        item_id: ItemId,
        amount: i32,
        force: bool,
        acquire_options: InventoryAcquireItemOptions,
        event_type: ItemStockChangedEventType,
    ) !re.sdk.ManagedObject {
        const inventory = self.inventory orelse return error.InventoryNotSet;
        const res = try inventory.call(
            .mergeOrAdd,
            scope,
            .fo(g.sdk),
            .{ item_id, amount, force, acquire_options, event_type },
        );
        try g.character_manager.call(.updateInveontoryForPlayer, scope, .fo(g.sdk), .{});
        return res;
    }

    pub inline fn addPreferentialPanel(
        self: InvenotryManagement,
        scope: *interop.Scope,
        item_id: ItemId,
        amount: i32,
        event_type: ItemStockChangedEventType,
    ) !InventoryPanelKey {
        const inventory = self.inventory orelse return error.InventoryNotSet;
        const res = try inventory.call(
            .addPreferentialPanel,
            scope,
            .fo(g.sdk),
            .{ item_id, amount, event_type },
        );
        try g.character_manager.call(.updateInveontoryForPlayer, scope, .fo(g.sdk), .{});
        return res;
    }

    pub inline fn hasPanel(self: InvenotryManagement, scope: *interop.Scope, panel_key: InventoryPanelKey) !bool {
        const inventory = self.inventory orelse return error.InventoryNotSet;
        const res = try inventory.call(
            .hasPanel,
            scope,
            .fo(g.sdk),
            .{panel_key},
        );
        return res;
    }
};

pub const ObjectiveManagement = struct {
    objectives: std.ArrayList(CurrentObjectiveDetails) = .empty,

    pub fn update(self: *ObjectiveManagement, arena: std.mem.Allocator, scope: *interop.Scope) !void {
        self.objectives = .empty;

        const infos = try g.objective_manager.call(.getObjectiveInfoArray, scope, .fo(g.sdk), .{});
        const infos_len: usize = @intCast(try infos.getLength(scope, .fo(g.sdk)));
        try self.objectives.ensureTotalCapacity(arena, infos_len);

        for (0..infos_len) |i| {
            const idx: i32 = @intCast(i);
            const info_mo = (infos.getValue(idx, scope, .fo(g.sdk)) catch continue) orelse continue;
            const info = CurrentObjectiveInfo.init(&g.interop_cache, .fo(g.sdk), info_mo) catch continue;
            const details = CurrentObjectiveDetails.copyFrom(info, arena, scope, .fo(g.sdk)) catch continue;
            try self.objectives.append(arena, details);
        }
    }

    pub inline fn objectivesSlice(self: ObjectiveManagement) []const CurrentObjectiveDetails {
        return self.objectives.items;
    }

    pub inline fn requestAchieveObjective(scope: *interop.Scope, objective_id: ObjectiveID, is_silent: bool) !void {
        return g.objective_manager.call(.requestAchieveObjective, scope, .fo(g.sdk), .{ objective_id, is_silent });
    }

    pub inline fn requestSetObjective(scope: *interop.Scope, objective_id: ObjectiveID, is_silent: bool) !void {
        return g.objective_manager.call(.requestSetObjective, scope, .fo(g.sdk), .{ objective_id, is_silent });
    }

    pub inline fn requestCountObjective(scope: *interop.Scope, objective_id: ObjectiveID, is_silent: bool, is_open_map: bool) !void {
        // app.LevelFlowBehaviorTreeAction_FSM_ObjectiveAction.start(via.behaviortree.ActionArg)
        // app.LevelFlowBehaviorTreeAction_FSM_ObjectiveAction.requestObjective()
        // app.ObjectiveManager.onLateUpdate()
        return g.objective_manager.call(.requestCountObjective, scope, .fo(g.sdk), .{ objective_id, is_silent, is_open_map });
    }

    pub inline fn isOpenMap(scope: *interop.Scope, objective_id: ObjectiveID) !bool {
        return g.objective_manager.call(.isOpenMap, scope, .fo(g.sdk), .{objective_id});
    }
};

pub const LevelFlowManagedObjects = struct {
    collection: std.ArrayList(LevelFlowManagedObject) = .empty,
    arena: std.heap.ArenaAllocator,

    inline fn collect(self: *LevelFlowManagedObjects, level_flow_mo: LevelFlowManagedObject) !void {
        const arena = self.arena.allocator();

        var scope = g.interop_cache.newScope(arena);
        defer scope.deinit();

        try self.collection.append(arena, level_flow_mo);
    }

    fn reset(self: *LevelFlowManagedObjects) void {
        _ = self.arena.reset(.retain_capacity);
        self.collection = .empty;
    }
};

pub const Player = struct {
    player_context: PlayerContext,
    scope: interop.Scope,
    hand_inventory: InvenotryManagement = .{},
    item_box_inventory: InvenotryManagement = .{},
    objective_mg: ObjectiveManagement = .{},

    fn init() !Player {
        var scope = g.interop_cache.newScope(g.allocator);

        const player_context = (try g.character_manager.call(.getPlayerContextRef, &scope, .fo(g.sdk), .{})) orelse
            return error.PlayerContextNotFound;

        return .{
            .player_context = player_context,
            .scope = scope,
        };
    }

    pub fn checkInventory(self: *Player) !void {
        defer self.scope.reset();
        const arena = Arena(.player_inventory);
        _ = arena.reset(.retain_capacity);

        const inventory_user = try self.player_context.call(.get_InventoryUserID, &self.scope, .fo(g.sdk), .{});

        {
            const inventory = (try g.inventory_manager.call(
                .getInventory,
                &self.scope,
                .fo(g.sdk),
                .{ inventory_user, InventoryType.hand },
            )) orelse return error.HandInventoryNotFound;
            log.debug("Hand Inventory: 0x{x}", .{@intFromPtr(inventory.managed.raw)});
            try self.hand_inventory.update(arena.allocator(), inventory, &self.scope);
        }

        {
            const inventory = (try g.inventory_manager.call(
                .getInventory,
                &self.scope,
                .fo(g.sdk),
                .{ inventory_user, InventoryType.itembox },
            )) orelse return error.ItemBoxInventoryNotFound;
            log.debug("Item Box Inventory: 0x{x}", .{@intFromPtr(inventory.managed.raw)});
            try self.item_box_inventory.update(arena.allocator(), inventory, &self.scope);
        }
    }

    pub fn checkObjectives(self: *Player) !void {
        defer self.scope.reset();
        const arena = Arena(.player_objectives);
        _ = arena.reset(.retain_capacity);

        try self.objective_mg.update(arena.allocator(), &self.scope);
    }

    fn deinit(self: *Player) void {
        self.scope.deinit();
    }
};

fn tdbGetMethod(tdb: re.sdk.Tdb, comptime type_name: [:0]const u8, comptime method_sig: [:0]const u8) !?*interop.MethodMetadata {
    const type_def = tdb.findType(.fo(g.sdk), type_name) orelse return null;
    const metadata = try g.interop_cache.getOrCacheMethodMetadata(.fo(g.sdk), type_def, method_sig);
    return metadata;
}

fn onStart() !void {
    g.api.lockLua();
    defer g.api.unlockLua();
    try g.items.populateItemCategories();
}

fn onPlayerInitialized() !void {
    g.api.lockLua();
    defer g.api.unlockLua();

    try g.interop_cache.resetDiagnostics();

    log.debug("Collected item-pickups: {}", .{g.item_pickups.collection.items.len});
    try g.item_pickups.mapPickupsWithItemId();

    log.debug("Collected level flow managed objects: {}", .{g.level_flow_managed_objects.collection.items.len});
    {
        var scope = g.interop_cache.newScope(g.allocator);
        defer scope.deinit();

        for (g.level_flow_managed_objects.collection.items) |flow| {
            const component: *interop.ViaComponent = @ptrCast(flow.managed.raw);
            const next_component_mo: re.sdk.ManagedObject = .{ .raw = @ptrCast(@alignCast(component.nextComponent() orelse continue)) };
            const next_component = managed_types.LFBTA_FSM_GameJumpAction_LevelFlowGameJumpActionParam.init(&g.interop_cache, .fo(g.sdk), next_component_mo) catch |e| {
                if (e == error.TypeDefMismatch) continue;
                log.err("Error initializing LFBTA_FSM_GameJumpAction_LevelFlowGameJumpActionParam: {}, context: {s}", .{ e, try g.interop_cache.ownDiagnostics() });
                continue;
            };

            const game_obj = GameObject.init(&g.interop_cache, .fo(g.sdk), component.getOwner()) catch |e| {
                log.err("Error getting GameObject: {}, context: {s}", .{ e, try g.interop_cache.ownDiagnostics() });
                continue;
            };
            const game_obj_name_sys_str = game_obj.call(.get_Name, &scope, .fo(g.sdk), .{}) catch |e| {
                log.err("Error getting GameObject-Name: {}, context: {s}", .{ e, try g.interop_cache.ownDiagnostics() });
                continue;
            };
            const game_obj_name = try std.unicode.utf16LeToUtf8Alloc(scope.arena.allocator(), game_obj_name_sys_str.data);
            log.debug("Level Flow Managed Object: 0x{x}, Name: {s}(0x{x}), Next: 0x{x}", .{
                @intFromPtr(flow.managed.raw),
                game_obj_name,
                @intFromPtr(game_obj.managed.raw),
                @intFromPtr(next_component.managed.raw),
            });
        }
    }

    g.player = try .init();
    try g.player.?.checkInventory();
    try g.player.?.checkObjectives();
}

fn onPlayerUnlinked() void {
    g.api.lockLua();
    defer g.api.unlockLua();

    g.items.reset();
    g.item_pickups.reset();
    g.level_flow_managed_objects.reset();

    const player = &(g.player orelse return);
    player.deinit();

    g.player = null;
}

fn onPlayerItemChange() !void {
    g.api.lockLua();
    defer g.api.unlockLua();

    const player = &(g.player orelse return);
    try player.checkInventory();
}

fn onChangeObjective() !void {
    g.api.lockLua();
    defer g.api.unlockLua();

    const player = &(g.player orelse return);
    try player.checkObjectives();
}

fn installHooks() !void {
    const onStartFn = (try tdbGetMethod(g.tdb, "app.LevelPlayerCreateController", "start()")) orelse
        return error.StartMethodNotFound;
    _ = onStartFn.handle.addHook(
        .fo(g.sdk.safe().functions),
        null,
        struct {
            fn func(_: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                onStart() catch |e| {
                    log.err("Error onStart: {}", .{e});
                };
            }
        }.func,
        false,
    );

    const ItemCoreT = try ItemCore.Runtime.getWithTdb(&g.interop_cache, .fo(g.sdk), g.tdb);
    _ = ItemCoreT.getMethod(.onPickup).addHook(
        .fo(g.sdk.safe().functions),
        struct {
            fn func(args_opt: ?[]?*anyopaque, _: ?[]re.sdk.TypeDefinition, _: u64) re.api.HookCall {
                const args = args_opt orelse return .call_original;
                if (args.len < 2) return .call_original;

                const this_ptr = args[1] orelse return .call_original;
                const this_mo: re.sdk.ManagedObject = .{ .raw = @ptrCast(@alignCast(this_ptr)) };
                const this = ItemCore.init(&g.interop_cache, .fo(g.sdk), this_mo) catch |e| {
                    log.err("Error in ItemCore init: {}", .{e});
                    return .call_original;
                };

                g.api.lockLua();
                defer g.api.unlockLua();
                g.item_pickups.removeItem(this);

                return .call_original;
            }
        }.func,
        null,
        false,
    );

    // app.InteractActionItemPickup.setup(app.InteractActionItemPickupHolder, app.ItemCore)
    const InteractActionItemPickupT = try InteractActionItemPickup.Runtime.getWithTdb(&g.interop_cache, .fo(g.sdk), g.tdb);
    _ = InteractActionItemPickupT.getMethod(.@".ctor").addHook(
        .fo(g.sdk.safe().functions),
        struct {
            fn func(args_opt: ?[]?*anyopaque, _: ?[]re.sdk.TypeDefinition, _: u64) re.api.HookCall {
                const args = args_opt orelse return .call_original;
                if (args.len < 2) return .call_original;

                const this_ptr = args[1] orelse return .call_original;
                const this_mo: re.sdk.ManagedObject = .{ .raw = @ptrCast(@alignCast(this_ptr)) };
                const this = InteractActionItemPickup.init(&g.interop_cache, .fo(g.sdk), this_mo) catch |e| {
                    log.err("Error in InteractActionItemPickup init: {}", .{e});
                    return .call_original;
                };

                g.api.lockLua();
                defer g.api.unlockLua();
                g.item_pickups.collect(this) catch {};

                return .call_original;
            }
        }.func,
        null,
        false,
    );

    _ = g.level_flow_manager.runtime.getMethod(.registerManagedObject).addHook(
        .fo(g.sdk.safe().functions),
        struct {
            fn func(args_opt: ?[]?*anyopaque, _: ?[]re.sdk.TypeDefinition, _: u64) re.api.HookCall {
                const args = args_opt orelse return .call_original;
                if (args.len < 3) return .call_original;

                const this_ptr = args[2] orelse return .call_original;
                const this_mo: re.sdk.ManagedObject = .{ .raw = @ptrCast(@alignCast(this_ptr)) };
                const this = LevelFlowManagedObject.init(&g.interop_cache, .fo(g.sdk), this_mo) catch |e| {
                    log.err("Error in LevelFlowManagedObject init: {}", .{e});
                    return .call_original;
                };

                g.api.lockLua();
                defer g.api.unlockLua();
                g.level_flow_managed_objects.collect(this) catch {};

                return .call_original;
            }
        }.func,
        null,
        false,
    );

    const LFBTA_FSM_GameJumpActionT = try LFBTA_FSM_GameJumpAction.Runtime.getWithTdb(&g.interop_cache, .fo(g.sdk), g.tdb);
    _ = LFBTA_FSM_GameJumpActionT.getMethod(.@".ctor").addHook(
        .fo(g.sdk.safe().functions),
        struct {
            fn func(args_opt: ?[]?*anyopaque, _: ?[]re.sdk.TypeDefinition, _: u64) re.api.HookCall {
                const args = args_opt orelse return .call_original;
                if (args.len < 2) return .call_original;
                const this_ptr = args[1] orelse return .call_original;
                const this_mo: re.sdk.ManagedObject = .{ .raw = @ptrCast(@alignCast(this_ptr)) };
                const this = LFBTA_FSM_GameJumpAction.init(&g.interop_cache, .fo(g.sdk), this_mo) catch |e| {
                    if (e == error.TypeDefMismatch) return .call_original;
                    log.err("Error in LFBTA_FSM_GameJumpAction init: {}", .{e});
                    return .call_original;
                };

                g.api.lockLua();
                defer g.api.unlockLua();

                //const arena = g.game_jumps.arena.allocator();

                const type_def = this.managed.getTypeDefinition(.fo(g.sdk)) orelse return .call_original;
                const type_name = type_def.getFullNameAlloc(.fo(g.sdk), g.allocator) catch return .call_original;
                defer g.allocator.free(type_name);

                log.debug("GameJump({s}) .ctor: 0x{x}", .{ type_name, @intFromPtr(this.managed.raw) });

                //g.game_jumps.collect(this) catch {};

                return .call_original;
            }
        }.func,
        null,
        false,
    );

    // app.Inventory.addPanel(app.ItemAmountData, via.Int2, app.InventoryPanelRotateType, app.ItemStockChangedEventType)
    const addPanelFn = (try tdbGetMethod(g.tdb, "app.Inventory", "addPanel(app.ItemAmountData, via.Int2, app.InventoryPanelRotateType, app.ItemStockChangedEventType)")) orelse
        return error.AddPanelMethodNotFound;
    _ = addPanelFn.handle.addHook(
        .fo(g.sdk.safe().functions),
        null,
        struct {
            fn func(_: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                onPlayerItemChange() catch |e| {
                    log.err("Error addPanelHook: {}", .{e});
                };
            }
        }.func,
        false,
    );

    // app.GuiManagerBehavior
    // onItemAcquired(app.ItemAcquiredInfo)
    // onItemStockChanged(app.InventoryStockEventArgs)
    // app.TutorialObserver
    // onUsedEvent(app.InventoryCommandEventArgs)

    const onItemAcquiredFn = (try tdbGetMethod(g.tdb, "app.GuiManagerBehavior", "onItemAcquired(app.ItemAcquiredInfo)")) orelse
        return error.OnItemAcquiredMethodNotFound;
    _ = onItemAcquiredFn.handle.addHook(
        .fo(g.sdk.safe().functions),
        null,
        struct {
            fn func(_: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                onPlayerItemChange() catch |e| {
                    log.err("Error onItemAcquired: {}", .{e});
                };
            }
        }.func,
        false,
    );

    const onItemStockChangedFn = (try tdbGetMethod(g.tdb, "app.GuiManagerBehavior", "onItemStockChanged(app.InventoryStockEventArgs)")) orelse
        return error.OnItemStockChangedMethodNotFound;
    _ = onItemStockChangedFn.handle.addHook(
        .fo(g.sdk.safe().functions),
        null,
        struct {
            fn func(_: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                onPlayerItemChange() catch |e| {
                    log.err("Error onItemStockChanged: {}", .{e});
                };
            }
        }.func,
        false,
    );

    const onUsedEventFn = (try tdbGetMethod(g.tdb, "app.TutorialObserver", "onUsedEvent(app.InventoryCommandEventArgs)")) orelse
        return error.OnUsedEventMethodNotFound;
    _ = onUsedEventFn.handle.addHook(
        .fo(g.sdk.safe().functions),
        null,
        struct {
            fn func(_: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                onPlayerItemChange() catch |e| {
                    log.err("Error onUsedEvent: {}", .{e});
                };
            }
        }.func,
        false,
    );

    const CharacterManagerT = try CharacterManager.Runtime.getWithTdb(&g.interop_cache, .fo(g.sdk), g.tdb);
    _ = CharacterManagerT.getMethod(.notifyPlayerInitialized).addHook(
        .fo(g.sdk.safe().functions),
        null,
        struct {
            fn func(_: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                onPlayerInitialized() catch |e| {
                    if (g.interop_cache.ownDiagnostics()) |diags| {
                        if (diags.len > 0) {
                            log.err("Cache context: {s}", .{diags});
                        }
                    } else |_| {}
                    log.err("Error notifyPlayerInitialized: {}", .{e});
                };
            }
        }.func,
        false,
    );

    const PlayerContextT = try PlayerContext.Runtime.getWithTdb(&g.interop_cache, .fo(g.sdk), g.tdb);
    _ = PlayerContextT.getMethod(.onUnlinked).addHook(
        .fo(g.sdk.safe().functions),
        null,
        struct {
            fn func(_: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                onPlayerUnlinked();
            }
        }.func,
        false,
    );

    const onChangeObjectiveFn = (try tdbGetMethod(g.tdb, "app.AnalysisLogManagerAppBehavior", "onChangeObjective(app.ObjectiveChangeEventArg)")) orelse
        return error.OnChangeObjectiveMethodNotFound;
    _ = onChangeObjectiveFn.handle.addHook(
        .fo(g.sdk.safe().functions),
        null,
        struct {
            fn func(_: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                onChangeObjective() catch |e| {
                    log.err("Error onChangeObjective: {}", .{e});
                };
            }
        }.func,
        false,
    );
}

fn init(api: re.Api) !void {
    try g.init(api);
    try ui.init();

    log.info(
        "RE9 Forced Hacks in Zig! Required REFramework Version: {}.{}.{}",
        .{
            re.PluginVersion.default.major,
            re.PluginVersion.default.minor,
            re.PluginVersion.default.patch,
        },
    );

    try installHooks();
}

fn onUpdate() void {}

fn onDeviceReset() void {
    log.info("Device reset detected, clearing interop cache", .{});

    g.reset();
}

comptime {
    re.initPlugin(init, .{
        .requiredVersion = .{
            .gameName = "RE9",
        },
        // .onPreApplicationEntry = &.{
        //     .{ "UpdateBehavior", onUpdate },
        // },
        .onDeviceReset = onDeviceReset,
        .onImGuiDrawUI = struct {
            fn func(data: *re.API_C.REFImGuiFrameCbData) void {
                ui.draw(data) catch |e| {
                    log.err("Error in UI draw: {}", .{e});
                };
            }
        }.func,
    });
}

pub export fn DllMain(
    hinstDLL: windows.HINSTANCE,
    fdwReason: windows.DWORD,
    lpReserved: windows.LPVOID,
) callconv(.winapi) windows.BOOL {
    _ = hinstDLL;
    _ = lpReserved;

    switch (fdwReason) {
        win32.system.system_services.DLL_PROCESS_ATTACH => {
            g.attach();
        },
        win32.system.system_services.DLL_PROCESS_DETACH => {},
        else => {},
    }

    return .TRUE;
}
