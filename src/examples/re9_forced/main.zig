const std = @import("std");

const re = @import("reframework");

const win32 = @import("win32");
const cimgui = @import("cimgui");

const managed_types = @import("managed_types.zig");
const ui = @import("ui.zig");

const windows = std.os.windows;

const interop = re.interop;

const SystemArray = managed_types.SystemArray;
const SystemEventCallback = managed_types.SystemEventCallback;
const PlayerContext = managed_types.PlayerContext;
const ItemDetails = managed_types.ItemDetails;
const PanelItemDetails = managed_types.PanelItemDetails;
const ItemDetailData = managed_types.ItemDetailData;
const ItemCategory = managed_types.ItemCategory;
const ItemId = managed_types.ItemId;
const Inventory = managed_types.Inventory;
const InventoryType = managed_types.InventoryType;
const InventoryAcquireItemOptions = managed_types.InventoryAcquireItemOptions;
const InventoryPanelKey = managed_types.InventoryPanelKey;
const InventoryPanelItemInfo = managed_types.InventoryPanelItemInfo;
const ItemStockChangedEventType = managed_types.ItemStockChangedEventType;
const ItemCore = managed_types.ItemCore;
const InteractActionItemPickup = managed_types.InteractActionItemPickup;
const FileID = managed_types.FileID;
const FileDetailData = managed_types.FileDetailData;
const FileAcquireOptionBit = managed_types.FileAcquireOptionBit;
const FileDetails = managed_types.FileDetails;
const FileInventory = managed_types.FileInventory;
const ObjectiveID = managed_types.ObjectiveID;
const CurrentObjectiveDetails = managed_types.CurrentObjectiveDetails;
const CurrentObjectiveInfo = managed_types.CurrentObjectiveInfo;
const LevelFlowManagedObject = managed_types.LevelFlowManagedObject;
const LevelFlowObject = managed_types.LevelFlowObject;
const LevelFlowController = managed_types.LevelFlowController;
const GameObject = managed_types.GameObject;
const LevelProgressID = managed_types.LevelProgressID;
const BT_ActionArg = managed_types.BT_ActionArg;
const LFBTA_FSM_GameJumpAction = managed_types.LFBTA_FSM_GameJumpAction;
const LFBTA_FSM_GameJumpAction_GameJumpData = managed_types.LFBTA_FSM_GameJumpAction_GameJumpData;
const GameJumpFlowObject = managed_types.GameJumpFlowObject;
const GameJumpData = managed_types.GameJumpData;

const EnemyRoleAction = managed_types.EnemyRoleAction;
const EnemySpawnParamDetails = managed_types.EnemySpawnParamDetails;

const ItemManager = managed_types.ItemManager;
const FileManager = managed_types.FileManager;
const CharacterManager = managed_types.CharacterManager;
const InventoryManager = managed_types.InventoryManager;
const ObjectiveManager = managed_types.ObjectiveManager;
const SaveServiceManager = managed_types.SaveServiceManager;
const SceneTransitionManager = managed_types.SceneTransitionManager;
const LevelFlowManager = managed_types.LevelFlowManager;

const ResolvedSceneManagerType = interop.ResolvedType("via.SceneManager");

const GenericDictionary = managed_types.GenericDictionary;
const ConcurrentCatalogDictionary = managed_types.ConcurrentCatalogDictionary;

const BehaviorTree = @import("behavior_tree.zig").BehaviorTree;
const BehaviorTreeManaged = managed_types.BehaviorTree;

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

pub const is_debug = @import("builtin").mode == .Debug;
const log = std.log.scoped(if (is_debug) .re9_forced_debug else .re9_forced);

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

    pub var item_manager: ItemManager = undefined;
    pub var file_manager: FileManager = undefined;
    pub var character_manager: CharacterManager = undefined;
    pub var inventory_manager: InventoryManager = undefined;
    pub var objective_manager: ObjectiveManager = undefined;
    pub var save_sevice_manager: SaveServiceManager = undefined;
    pub var scene_transition_manager: SceneTransitionManager = undefined;
    pub var level_flow_manager: LevelFlowManager = undefined;

    pub var scene_manager: *anyopaque = undefined;
    pub var SceneManagerT: ResolvedSceneManagerType = undefined;

    pub var items: Items = undefined;
    pub var files: Files = undefined;
    pub var level_flow_managed_objects: LevelFlowManagedObjects = undefined;
    pub var btree_management: BehaviorTreeManagement = undefined;
    pub var item_pickups: ItemPickups = undefined;
    pub var player: ?Player = null;

    pub var scene_enemy_management: SceneEnemyManagement = undefined;

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    var threaded: std.Io.Threaded = undefined;

    fn init(init_api: re.Api) !void {
        api = init_api;
        sdk = try api.verifiedSdk(verified_sdk_spec);
        tdb = re.sdk.getTdb(.fo(g.sdk)) orelse return error.TdbNotFound;

        items = .{ .arena = .init(allocator) };
        item_pickups = .{ .arena = .init(allocator) };
        files = .{ .arena = .init(allocator) };
        level_flow_managed_objects = .{ .arena = .init(allocator) };
        btree_management = .{ .arena = .init(allocator) };

        SceneManagerT = try g.interop_cache.resolve(ResolvedSceneManagerType.fullTypeName(), g.tdb, .fo(g.sdk));
        scene_enemy_management = .{ .arena = .init(allocator) };

        item_manager = try ItemManager.init(
            &g.interop_cache,
            .fo(g.sdk),
            re.sdk.getManagedSingleton(.fo(g.sdk), ItemManager.fullTypeName()) orelse
                return error.ItemManagerNotFound,
        );
        file_manager = try FileManager.init(
            &g.interop_cache,
            .fo(g.sdk),
            re.sdk.getManagedSingleton(.fo(g.sdk), FileManager.fullTypeName()) orelse
                return error.FileManagerNotFound,
        );
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
        scene_manager = re.sdk.getNativeSingleton(.fo(g.sdk), ResolvedSceneManagerType.fullTypeName()) orelse
            return error.SceneManagerNotFound;
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

    pub inline fn sceneManager(scope: *interop.Scope) ResolvedSceneManagerType.Instanced(?*anyopaque) {
        return SceneManagerT.scoped(scope).instanced(g.scene_manager);
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
        const pickup_detail = pickups.getLast() orelse return;
        const pickup = pickup_detail.pickup;

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

    pub fn startFlowActions(flow: LevelFlowManagedObject) !void {
        const component: *interop.ViaComponent = @ptrCast(flow.managed.raw);

        const BehaviorTreeT = try interop_cache.resolve(BehaviorTree.full_type_name, tdb, .fo(sdk));

        var child_component = component.childComponent();
        while (child_component) |child| : (child_component = child.childComponent()) {
            if (child == component) {
                break;
            }

            const child_mo = re.sdk.ManagedObject{ .raw = @ptrCast(@alignCast(child)) };
            if (!child_mo.isManagedObject(.fo(sdk))) {
                log.debug("Found non-managed-object child component: 0x{x}", .{@intFromPtr(child)});
                continue;
            }
            const child_type_def = child_mo.getTypeDefinition(.fo(sdk)) orelse continue;
            if (!child_type_def.isDerivedFrom(.fo(sdk), BehaviorTreeT.type_def_metadata.def)) {
                continue;
            }

            try startBehaviorTree(.fo(child_mo.raw));
        }
    }

    pub fn startFlowActionsNative(flow: LevelFlowManagedObject) !void {
        const component: *interop.ViaComponent = @ptrCast(flow.managed.raw);

        const BehaviorTreeT = try interop_cache.resolve(BehaviorTree.full_type_name, tdb, .fo(sdk));

        var child_component = component.childComponent();
        while (child_component) |child| : (child_component = child.childComponent()) {
            if (child == component) {
                break;
            }

            const child_mo = re.sdk.ManagedObject{ .raw = @ptrCast(@alignCast(child)) };
            if (!child_mo.isManagedObject(.fo(sdk))) {
                log.debug("Found non-managed-object child component: 0x{x}", .{@intFromPtr(child)});
                continue;
            }
            const child_type_def = child_mo.getTypeDefinition(.fo(sdk)) orelse continue;
            if (!child_type_def.isDerivedFrom(.fo(sdk), BehaviorTreeT.type_def_metadata.def)) {
                continue;
            }

            try startBehaviorTreeNative(.fo(child_mo.raw));
        }
    }

    pub fn startBehaviorTree(tree: *BehaviorTree) !void {
        var scope = interop_cache.newScope(allocator);
        defer scope.deinit();

        const handles = tree.getTrees();
        for (handles) |handle| {
            const tree_obj = handle.core.tree_object orelse continue;
            const action_arg = handle.core.action_arg;
            const actions_ptr = tree_obj.actions;
            const actions = actions_ptr.items[0..actions_ptr.len];

            for (actions) |action| {
                action_arg.owner_component = handle.core.owner_component;
                action_arg.owner_behavior_tree_core = &handle.core;

                try scope.callMethod(action, "start(via.behaviortree.ActionArg)", void, .fo(sdk), .{action_arg});
            }
        }
    }

    pub inline fn startBehaviorTreeNative(tree: *BehaviorTree) void {
        var vm_context = re.sdk.getVmContext(.fo(g.sdk)) orelse return;
        tree.startBehavior(&vm_context);
    }
};

pub const Items = struct {
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
                            break :blk e;
                        };
                        break :blk details;
                    };
                    const details = details_res catch |e| {
                        log.err("Failed to get details: {}, context: {s}", .{ e, try g.interop_cache.ownDiagnostics() });
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
        try self.populateCategories();
        try self.populate();
    }

    fn populateCategories(self: *Items) !void {
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

    fn populate(self: *Items) !void {
        var scope = g.interop_cache.newScope(g.allocator);
        defer scope.deinit();

        const item_catalog: *ConcurrentCatalogDictionary = try g.item_manager.get(._ItemCatalog, &scope, .fo(g.sdk));

        const dict = item_catalog._Dict;

        self.last_version = dict._version;

        const entries = interop.SystemArrayEntries.unsafe(dict._entries, .fo(g.sdk));
        if (entries.contained_type_def.getVmObjType(.fo(g.sdk)) != .valtype) {
            return error.UnexpectedContainedType;
        }

        var iter = IteratorEntries{
            .owner = self,
            .scope = &scope,
            .entries = entries,
        };
        while (try iter.next()) |_| {}
    }

    pub fn iterator(self: *Items, scope: *interop.Scope) !Iterator {
        const item_catalog: *ConcurrentCatalogDictionary = try g.item_manager.get(._ItemCatalog, scope, .fo(g.sdk));

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

pub const Files = struct {
    files: std.ArrayList(FileDetails) = .empty,
    arena: std.heap.ArenaAllocator,

    pub fn filesSlice(self: *const Files) []FileDetails {
        return self.files.items;
    }

    pub fn repopulate(self: *Files) !void {
        self.reset();

        const arena = self.arena.allocator();
        var scope = g.interop_cache.newScope(arena);
        defer scope.deinit();

        const file_catalog = try g.file_manager.get(._FileCatalog, &scope, .fo(g.sdk));
        const dict: *GenericDictionary = file_catalog._Dict;
        const entries = interop.SystemArrayEntries.unsafe(dict._entries, .fo(g.sdk));
        if (entries.contained_type_def.getVmObjType(.fo(g.sdk)) != .valtype) {
            return error.UnexpectedContainedType;
        }

        const element_size = entries.contained_type_def.getValueTypeSize(.fo(g.sdk));

        for (0..entries.len) |idx| {
            const entry_ptr_usize = @intFromPtr(entries.ptr) + (idx * element_size);
            const kvp = scope.getFieldFromTypeDef(
                @ptrFromInt(entry_ptr_usize),
                entries.contained_type_def,
                "value",
                re.sdk.ManagedObject,
                null,
                false,
                .fo(g.sdk),
            ) catch continue;
            const value = scope.getField(kvp, "_Value", FileDetailData, .fo(g.sdk)) catch continue;
            const details = FileDetails.copyFrom(value, arena, &scope, .fo(g.sdk)) catch continue;
            try self.files.append(arena, details);
        }
    }

    pub fn reset(self: *Files) void {
        _ = self.arena.reset(.retain_capacity);
        self.files = .empty;
    }
};

pub const ItemPickups = struct {
    collection: std.ArrayList(InteractActionItemPickup) = .empty,
    map: std.AutoHashMapUnmanaged(ItemId, std.ArrayList(struct {
        pickup: InteractActionItemPickup,
        detail: ItemDetails,
    })) = .empty,
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

        for (pickups.items, 0..) |pickup_detail, i| {
            const pickup = pickup_detail.pickup;
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

        const item_catalog = try g.item_manager.get(._ItemCatalog, &scope, .fo(g.sdk));
        const item_catalog_mo = re.sdk.ManagedObject{ .raw = @ptrCast(item_catalog) };

        const arena = self.arena.allocator();
        for (self.collection.items) |pickup| {
            const item_core = pickup.get(._ItemCore, &scope, .fo(g.sdk)) catch continue;
            const id = managed_types.getItemCoreItemID(item_core, &scope, .fo(g.sdk)) orelse {
                log.warn("Failed to get item-core item-id {s}", .{scope.cache.ownDiagnostics() catch ""});
                continue;
            };

            const result = try scope.callMethod(
                item_catalog_mo,
                "containsKey(app.ItemID)",
                bool,
                .fo(g.sdk),
                .{id},
            );
            if (!result) {
                log.warn(
                    "item not found in item catalog: id=0x{x}, core=0x{x}",
                    .{ @intFromPtr(id.raw), @intFromPtr(item_core.managed.raw) },
                );
                continue;
            }

            errdefer log.err("id=0x{x}", .{@intFromPtr(id.raw)});
            const detail = g.items.items_cache.get(id) orelse return error.ItemDetailsNotFound;

            const entry = try self.map.getOrPutValue(arena, id, .empty);
            try entry.value_ptr.append(arena, .{ .pickup = pickup, .detail = detail });
        }
    }

    fn reset(self: *ItemPickups) void {
        _ = self.arena.reset(.retain_capacity);
        self.collection = .empty;
        self.map = .empty;
    }
};

pub const InvenotryManagement = struct {
    items: std.ArrayList(PanelItemDetails) = .empty,
    inventory: ?Inventory = null,

    fn update(self: *InvenotryManagement, arena: std.mem.Allocator, inventory: Inventory, scope: *interop.Scope) !void {
        self.items = .empty;
        self.inventory = inventory;

        const panel_items = try inventory.get(._PanelItems, scope, .fo(g.sdk));

        const entries = interop.SystemArrayEntries.unsafe(panel_items._entries, .fo(g.sdk));
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

    pub inline fn mergeOrAddWithItemAmountData(
        self: InvenotryManagement,
        scope: *interop.Scope,
        amount_data: re.sdk.ManagedObject,
        force: bool,
        acquire_options: InventoryAcquireItemOptions,
        event_type: ItemStockChangedEventType,
    ) !re.sdk.ManagedObject {
        const inventory = self.inventory orelse return error.InventoryNotSet;
        const res = try inventory.call(
            .mergeOrAddWithItemAmountData,
            scope,
            .fo(g.sdk),
            .{ amount_data, force, acquire_options, event_type },
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

pub const FileInventoryManagement = struct {
    inventory: ?FileInventory = null,

    pub fn acquire(
        self: *const FileInventoryManagement,
        scope: *interop.Scope,
        file_id: FileID,
        acquire_option: FileAcquireOptionBit,
    ) !bool {
        const inventory = self.inventory orelse return error.InventoryNotSet;
        return inventory.call(
            .acquire,
            scope,
            .fo(g.sdk),
            .{ file_id, acquire_option },
        );
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

pub const BehaviorTreeManagement = struct {
    arena: std.heap.ArenaAllocator,
    mutex: std.Io.Mutex = .init,
    tree_actions: std.Deque(Action) = .empty,

    pub const ActionTag = enum {
        start,
        start_native,
        remove_native,
    };
    pub const Action = union(ActionTag) {
        start: *BehaviorTree,
        start_native: *BehaviorTree,
        remove_native: *BehaviorTree,

        fn fromTag(tag: ActionTag, payload: anytype) Action {
            // TODO: Update this when more action types are added..
            if (@TypeOf(payload) != *BehaviorTree) @compileError("payload must be a pointer to BehaviorTree");
            return switch (tag) {
                .start => .{ .start = payload },
                .start_native => .{ .start_native = payload },
                .remove_native => .{ .remove_native = payload },
            };
        }
    };

    pub fn queueFlowBTreeAction(self: *BehaviorTreeManagement, action: ActionTag, flow: LevelFlowManagedObject) !void {
        try self.mutex.lock(g.io);
        defer self.mutex.unlock(g.io);
        const arena = self.arena.allocator();

        const component: *interop.ViaComponent = @ptrCast(flow.managed.raw);

        const BehaviorTreeT = try g.interop_cache.resolve(BehaviorTree.full_type_name, g.tdb, .fo(g.sdk));

        var child_component = component.childComponent();
        while (child_component) |child| : (child_component = child.childComponent()) {
            if (child == component) {
                break;
            }

            const child_mo = re.sdk.ManagedObject{ .raw = @ptrCast(@alignCast(child)) };
            if (!child_mo.isManagedObject(.fo(g.sdk))) {
                log.debug("Found non-managed-object child component: 0x{x}", .{@intFromPtr(child)});
                continue;
            }
            const child_type_def = child_mo.getTypeDefinition(.fo(g.sdk)) orelse continue;
            if (!child_type_def.isDerivedFrom(.fo(g.sdk), BehaviorTreeT.type_def_metadata.def)) {
                continue;
            }

            try self.tree_actions.pushBack(arena, .fromTag(action, BehaviorTree.fo(child_mo.raw)));
        }
    }

    pub fn queueAction(self: *BehaviorTreeManagement, action: Action) !void {
        try self.mutex.lock(g.io);
        defer self.mutex.unlock(g.io);
        try self.tree_actions.pushBack(self.arena.allocator(), action);
    }

    pub fn performSingleAction(self: *BehaviorTreeManagement) !void {
        const next_action = blk: {
            try self.mutex.lock(g.io);
            defer self.mutex.unlock(g.io);

            break :blk self.tree_actions.popFront();
        };
        if (next_action) |action| {
            try switch (action) {
                .start => |tree| g.startBehaviorTree(tree),
                .start_native => |tree| g.startBehaviorTreeNative(tree),
                .remove_native => |tree| tree.removeFromExecutionQueue(),
            };
        }
    }

    pub fn reset(self: *BehaviorTreeManagement) void {
        self.mutex.lockUncancelable(g.io);
        defer self.mutex.unlock(g.io);
        _ = self.arena.reset(.retain_capacity);
        self.tree_actions = .empty;
    }
};

pub const LevelFlowManagedObjects = struct {
    collection: std.ArrayList(LevelFlowObject) = .empty,
    name_hashes: std.AutoHashMapUnmanaged(u32, i32) = .empty,
    arena: std.heap.ArenaAllocator,

    inline fn update(self: *LevelFlowManagedObjects) !void {
        self.reset();

        const arena = self.arena.allocator();
        var scope = g.interop_cache.newScope(arena);
        defer scope.deinit();

        const managed_objects: *GenericDictionary = g.level_flow_manager.get(._ManagedObjectList, &scope, .fo(g.sdk)) catch return;
        const entries = interop.SystemArrayEntries.unsafe(managed_objects._entries, .fo(g.sdk));
        if (entries.contained_type_def.getVmObjType(.fo(g.sdk)) != .valtype) {
            return error.UnexpectedContainedType;
        }
        const element_size = entries.contained_type_def.getValueTypeSize(.fo(g.sdk));
        for (0..entries.len) |idx| {
            const entry_ptr_usize = @intFromPtr(entries.ptr) + (idx * element_size);
            const managed_object_list = scope.getFieldFromTypeDef(
                @ptrFromInt(entry_ptr_usize),
                entries.contained_type_def,
                "value",
                re.sdk.ManagedObject,
                null,
                false,
                .fo(g.sdk),
            ) catch continue;
            const key = scope.getFieldFromTypeDef(
                @ptrFromInt(entry_ptr_usize),
                entries.contained_type_def,
                "key",
                u32,
                null,
                false,
                .fo(g.sdk),
            ) catch continue;
            const items = scope.getField(managed_object_list, "_items", SystemArray, .fo(g.sdk)) catch continue;
            const len = items.getLength(&scope, .fo(g.sdk)) catch continue;
            const name_hash_entry = try self.name_hashes.getOrPutValue(arena, key, 0);
            for (0..@intCast(len)) |i| {
                const mo = (items.getValue(i, &scope, .fo(g.sdk)) catch continue) orelse continue;
                const flow = try LevelFlowManagedObject.init(&g.interop_cache, .fo(g.sdk), mo);
                const flow_name = try flow.get(._FlowName, &scope, .fo(g.sdk));
                const name_hash = try flow_name.get(._Hash, &scope, .fo(g.sdk));
                name_hash_entry.value_ptr.* += 1;
                // storeToLocal has to be called to get rest of the data
                try self.collection.append(arena, .{ .component = flow, .name_hash = name_hash });
            }
        }

        try g.level_flow_managed_objects.storeToLocal();
    }

    fn getWithChildComponentType(self: *LevelFlowManagedObjects, type_def: re.sdk.TypeDefinition) ![]LevelFlowManagedObject {
        const arena = self.arena.allocator();

        var scope = g.interop_cache.newScope(arena);
        defer scope.deinit();

        var result: std.ArrayList(LevelFlowManagedObject) = .empty;
        defer result.deinit(arena);

        for (self.collection.items) |flow_obj| {
            const flow = flow_obj.component;
            const component: *interop.ViaComponent = @ptrCast(flow.managed.raw);
            var child_component = component.childComponent();
            while (child_component) |child| : (child_component = child.childComponent()) {
                if (child == component) {
                    break;
                }

                const child_mo = re.sdk.ManagedObject{ .raw = @ptrCast(@alignCast(child)) };
                if (!child_mo.isManagedObject(.fo(g.sdk))) {
                    log.debug("Found non-managed-object child component: 0x{x}", .{@intFromPtr(child)});
                    continue;
                }
                const child_type_def = child_mo.getTypeDefinition(.fo(g.sdk)) orelse continue;
                if (child_type_def.isDerivedFrom(.fo(g.sdk), type_def)) {
                    try result.append(arena, flow);
                }
            }
        }

        return result.toOwnedSlice(arena);
    }

    fn storeToLocal(self: *LevelFlowManagedObjects) !void {
        const arena = self.arena.allocator();

        var scope = g.interop_cache.newScope(arena);
        defer scope.deinit();

        const BehaviorTreeT = try g.interop_cache.resolve(BehaviorTree.full_type_name, g.tdb, .fo(g.sdk));

        for (self.collection.items) |*flow_obj| {
            const flow = flow_obj.component;
            const component: *interop.ViaComponent = @ptrCast(flow.managed.raw);

            const game_obj = try GameObject.init(&g.interop_cache, .fo(g.sdk), component.getOwner());

            const game_obj_name_sys_str = try game_obj.call(.get_Name, &scope, .fo(g.sdk), .{});
            const game_obj_name = try std.unicode.utf16LeToUtf8AllocZ(arena, game_obj_name_sys_str.data);

            var action_names: std.ArrayList([:0]const u8) = .empty;
            defer action_names.deinit(arena);

            var child_component = component.childComponent();
            while (child_component) |child| : (child_component = child.childComponent()) {
                if (child == component) {
                    break;
                }

                const child_mo = re.sdk.ManagedObject{ .raw = @ptrCast(@alignCast(child)) };
                if (!child_mo.isManagedObject(.fo(g.sdk))) {
                    log.debug("Found non-managed-object child component: 0x{x}", .{@intFromPtr(child)});
                    continue;
                }
                const child_type_def = child_mo.getTypeDefinition(.fo(g.sdk)) orelse continue;
                if (!child_type_def.isDerivedFrom(.fo(g.sdk), BehaviorTreeT.type_def_metadata.def)) {
                    continue;
                }

                const tree: *BehaviorTree = .fo(child_mo.raw);
                const handles = tree.getTrees();
                for (handles) |handle| {
                    const tree_obj = handle.core.tree_object orelse continue;
                    const actions_ptr = tree_obj.actions;
                    const actions = actions_ptr.items[0..actions_ptr.len];
                    for (actions) |action| {
                        const type_def = action.getTypeDefinition(.fo(g.sdk)) orelse continue;
                        const type_name = try type_def.getFullNameAlloc(.fo(g.sdk), arena);
                        defer arena.free(type_name);
                        const type_name_z = try arena.dupeSentinel(u8, type_name, 0);
                        try action_names.append(arena, type_name_z);
                    }
                }
            }

            if (action_names.items.len > 0) {
                flow_obj.data = .{
                    .owner_name = game_obj_name,
                    .action_names = try action_names.toOwnedSlice(arena),
                };
            }
        }
    }

    fn reset(self: *LevelFlowManagedObjects) void {
        _ = self.arena.reset(.retain_capacity);
        self.collection = .empty;
        self.name_hashes = .empty;
    }
};

pub const Player = struct {
    player_context: PlayerContext,
    scope: interop.Scope,
    hand_inventory: InvenotryManagement = .{},
    item_box_inventory: InvenotryManagement = .{},
    file_mg: FileInventoryManagement = .{},
    objective_mg: ObjectiveManagement = .{},
    game_jump_actions: std.ArrayList(GameJumpFlowObject) = .empty,

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
            log.info("Hand Inventory Found {} items.", .{self.hand_inventory.itemsSlice().len});
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
            log.info("Item Box Inventory Found {} items.", .{self.item_box_inventory.itemsSlice().len});
        }
    }

    pub fn checkFileInventory(self: *Player) !void {
        defer self.scope.reset();
        const file_inventory_user = try self.player_context.call(.get_FileInventoryUserID, &self.scope, .fo(g.sdk), .{});
        const file_inventory = try g.file_manager.call(
            .getFileInventory,
            &self.scope,
            .fo(g.sdk),
            .{file_inventory_user},
        ) orelse return error.FileInventoryNotFound;
        log.debug("FileInventory: 0x{x}", .{@intFromPtr(file_inventory.managed.raw)});
        self.file_mg.inventory = file_inventory;
    }

    pub fn checkObjectives(self: *Player) !void {
        defer self.scope.reset();
        const arena = Arena(.player_objectives);
        _ = arena.reset(.retain_capacity);

        try self.objective_mg.update(arena.allocator(), &self.scope);
    }

    pub fn checkGameJumps(self: *Player, flows: []LevelFlowManagedObject) !void {
        defer self.scope.reset();
        const arena = Arena(.player_game_jumps);
        _ = arena.reset(.retain_capacity);
        self.game_jump_actions = .empty;

        const LevelFlowGameJumpActionParamT = try managed_types.LFBTA_FSM_GameJumpAction_LevelFlowGameJumpActionParam
            .Runtime
            .get(&g.interop_cache, .fo(g.sdk));

        for (flows) |flow| {
            const component: *interop.ViaComponent = @ptrCast(flow.managed.raw);
            const game_obj = try GameObject.init(&g.interop_cache, .fo(g.sdk), component.getOwner());

            const game_obj_name_sys_str = try game_obj.call(.get_Name, &self.scope, .fo(g.sdk), .{});
            const game_obj_name = try std.unicode.utf16LeToUtf8AllocZ(arena.allocator(), game_obj_name_sys_str.data);

            var game_jump_datas: std.ArrayList(GameJumpData) = .empty;
            defer game_jump_datas.deinit(arena.allocator());

            var child_component = component.childComponent();
            while (child_component) |child| : (child_component = child.childComponent()) {
                if (child == component) {
                    break;
                }

                const child_mo = re.sdk.ManagedObject{ .raw = @ptrCast(@alignCast(child)) };
                if (!child_mo.isManagedObject(.fo(g.sdk))) {
                    log.debug("Found non-managed-object child component: 0x{x}", .{@intFromPtr(child)});
                    continue;
                }

                if (LevelFlowGameJumpActionParamT.isInstanceOf(.fo(g.sdk), child_mo)) {
                    const param = LevelFlowGameJumpActionParamT.forcedInstance(child_mo);
                    const param_datas: SystemArray = try param.call(.get_ParamArray, &self.scope, .fo(g.sdk), .{});
                    const len = try param_datas.getLength(&self.scope, .fo(g.sdk));
                    for (0..@intCast(len)) |i| {
                        const data_mo = (try param_datas.getValue(i, &self.scope, .fo(g.sdk))) orelse continue;
                        const data = try LFBTA_FSM_GameJumpAction_GameJumpData.init(&g.interop_cache, .fo(g.sdk), data_mo);
                        const data_details = try GameJumpData.copyFrom(data, arena.allocator(), &self.scope, .fo(g.sdk));
                        try game_jump_datas.append(arena.allocator(), data_details);
                    }
                }
            }

            const flow_name = try flow.get(._FlowName, &self.scope, .fo(g.sdk));
            const name_hash = try flow_name.get(._Hash, &self.scope, .fo(g.sdk));

            try self.game_jump_actions.append(arena.allocator(), .{
                .owner_component = flow,
                .name_hash = name_hash,
                .owner_name = game_obj_name,
                .jump_datas = try game_jump_datas.toOwnedSlice(arena.allocator()),
            });
        }
    }

    fn deinit(self: *Player) void {
        self.scope.deinit();
    }
};

const enemy_type_name_map: std.StaticStringMap([:0]const u8) = .initComptime(.{
    .{ "app.Cp_B000Context", "Zombie Male" },
    .{ "app.Cp_B001Context", "Zombie Female" },
    .{ "app.Cp_B003Context", "The Singer" },
    .{ "app.Cp_B004Context", "Zombie Cleaner" },
    .{ "app.Cp_B005Context", "Zombie Patient" },
    .{ "app.Cp_B006Context", "Zombie Patient" },
    .{ "app.Cp_B007Context", "Zombie Staff" },
    .{ "app.Cp_B030Context", "Zombie Patient" },
    .{ "app.Cp_B032Context", "The Chef" },
    .{ "app.Cp_B050Context", "Zombie RC" },
    .{ "app.Cp_B051Context", "Zombie RC Chainsaw" },
    .{ "app.Cp_B052Context", "Blister Borne" },
    .{ "app.Cp_B053Context", "Zombie RC Elite" },
    .{ "app.Cp_B054Context", "Zombie RC" },
    .{ "app.Cp_B060Context", "Zombie BSAA" },
    .{ "app.Cp_B070Context", "Zombie ARK" },
    .{ "app.Cp_B100Context", "The Chunk" },
    .{ "app.Cp_B200Context", "Norman Cole" },
    .{ "app.Cp_B600Context", "Licker Beta 2" },
    .{ "app.Cp_B700Context", "Titan Spinner" },
    .{ "app.Cp_B800Context", "The Girl" },
    .{ "app.Cp_B802Context", "The Chef" },
    .{ "app.Cp_B805Context", "The Girl" },
    .{ "app.Cp_C200Context", "Garmr" },
    .{ "app.Cp_C400Context", "Victor Gideon (Bike)" },
    .{ "app.Cp_C500Context", "Tyrant T-501" },
    .{ "app.Cp_C510Context", "Super Tyrant (T-501)" },
    .{ "app.Cp_C600Context", "Elite Guard" },
    .{ "app.Cp_C610Context", "The Commander" },
    .{ "app.Cp_C700Context", "Minion Spinner" },
    .{ "app.Cp_C800Context", "Plant 43 Minion" },
    .{ "app.Cp_C900Context", "Plant 43" },
    .{ "app.Cp_C901Context", "Plant 43 Minion" },
    .{ "app.Cp_D000Context", "Children" },
    .{ "app.Cp_D100Context", "Victor Gideon" },
    .{ "app.Cp_D110Context", "Victor Gideon (Mutated)" },
});
fn getEnemyTypeName(type_def: re.sdk.TypeDefinition, max_hp: i32) [:0]const u8 {
    const type_name = type_def.getFullNameAlloc(.fo(g.sdk), g.allocator) catch
        return "Unknown";
    defer g.allocator.free(type_name);
    if (std.mem.eql(u8, type_name, "app.Cp_B802Context")) {
        if (max_hp >= 1000000) {
            return "The Girl";
        }
        return "The Chef";
    }
    if (std.mem.eql(u8, type_name, "app.Cp_C500Context") or
        std.mem.eql(u8, type_name, "app.Cp_C510Context"))
    {
        if (max_hp >= 1000000) {
            return "Tyrant T-501";
        }
        return "Super Tyrant (T-501)";
    }
    return enemy_type_name_map.get(type_name) orelse "Unknown";
}

fn getMemberCopyAndSet(
    scope: *interop.Scope,
    parent: re.sdk.ManagedObject,
    comptime get_method: [:0]const u8,
    comptime set_method: [:0]const u8,
) !re.sdk.ManagedObject {
    errdefer log.err("{s} failed", .{get_method});
    const value = try scope.callMethod(parent, get_method, re.sdk.ManagedObject, .fo(g.sdk), .{});
    const copied_value = try scope.callMethod(value, "MemberwiseClone()", re.sdk.ManagedObject, .fo(g.sdk), .{});
    copied_value.addRef(.fo(g.sdk));
    errdefer {
        log.err("{s} failed", .{set_method});
        if (copied_value.getRefCount(.fo(g.sdk)) > 0)
            copied_value.release(.fo(g.sdk));
    }
    try scope.callMethod(parent, set_method, void, .fo(g.sdk), .{copied_value});
    return copied_value;
}

fn getFieldCopyAndSet(scope: *interop.Scope, parent: re.sdk.ManagedObject, comptime field: @EnumLiteral()) !re.sdk.ManagedObject {
    const value = try scope.getField(parent, @tagName(field), re.sdk.ManagedObject, .fo(g.sdk));
    const copied_value = try scope.callMethod(value, "MemberwiseClone()", re.sdk.ManagedObject, .fo(g.sdk), .{});
    copied_value.addRef(.fo(g.sdk));
    errdefer {
        log.err("set {s} failed", .{@tagName(field)});
        if (copied_value.getRefCount(.fo(g.sdk)) > 0)
            copied_value.release(.fo(g.sdk));
    }
    try scope.setField(parent, @tagName(field), .fo(g.sdk), copied_value);
    return copied_value;
}

fn safeFreeManagedObject(obj: re.sdk.ManagedObject) void {
    if (obj.getRefCount(.fo(g.sdk)) > 0)
        obj.release(.fo(g.sdk));
}

pub const EnemySpawnParams = struct {
    position: @Vector(3, f32),
    role_actions: []EnemyRoleAction,
    overrwrite_way_points: ?struct {
        start: @Vector(3, f32),
        end: @Vector(3, f32),
    } = null,
};

pub const SceneEnemyManagement = struct {
    enemies: std.ArrayList(EnemySpawnParamDetails) = .empty,
    // TODO: re-instantiate the GameObject.. or find a better way to copy the object
    spawned_enemies: std.ArrayList(struct {
        copied_base: re.sdk.ManagedObject,
        copied_spawn_data: re.sdk.ManagedObject,
        copied_enemy_settings: re.sdk.ManagedObject,
        copied_role_settings: re.sdk.ManagedObject,
        copied_coord_data: re.sdk.ManagedObject,
        copied_role_action_pool: re.sdk.ManagedObject,
        copied_role_actions_list: re.sdk.ManagedObject,
        copied_role_actions: []re.sdk.ManagedObject,
        new_spawn_context_id: re.sdk.ManagedObject,
    }) = .empty,
    arena: std.heap.ArenaAllocator,
    current_scene_name: ?[:0]const u8 = null,

    spawn_queue: std.Deque(struct { EnemySpawnParamDetails, EnemySpawnParams }) = .empty,
    mutex: std.Io.Mutex = .init,

    fn update(self: *SceneEnemyManagement) !void {
        self.reset();

        log.debug("Updating SceneEnemyManagement", .{});
        const arena = self.arena.allocator();

        var scope = g.interop_cache.newScope(arena);
        defer scope.deinit();

        const SceneT = try g.interop_cache.resolve("via.Scene", g.tdb, .fo(g.sdk));

        const scene_manager = g.SceneManagerT.scoped(&scope).instanced(g.scene_manager);
        const current_scene = try scene_manager.call("get_CurrentScene", re.sdk.ManagedObject, .fo(g.sdk), .{});
        log.debug("Current scene: {*}", .{current_scene.raw});
        const current_scene_name_sys_str = try SceneT.scoped(&scope).call(
            current_scene,
            "get_Name()",
            interop.SystemStringView,
            .fo(g.sdk),
            .{},
        );
        self.current_scene_name = if (current_scene_name_sys_str.data.len > 0)
            try std.unicode.utf16LeToUtf8AllocZ(arena, current_scene_name_sys_str.data)
        else
            null;

        const enemy_spawn_param_base_type = re.sdk.typeof(.fo(g.sdk), "app.EnemySpawnParamBase") orelse
            return error.EnemySpawnParamBaseNotFound;
        const EnemySpawnParamBaseT = try g.interop_cache.resolve("app.EnemySpawnParamBase", g.tdb, .fo(g.sdk));
        const CharacterContextT = try g.interop_cache.resolve("app.CharacterContext", g.tdb, .fo(g.sdk));

        const components = try SceneT.scoped(&scope).call(
            current_scene,
            "findComponents(System.Type)",
            interop.SystemArray,
            .fo(g.sdk),
            .{enemy_spawn_param_base_type},
        );
        const len = try components.getLength(&scope, .fo(g.sdk));

        for (0..@intCast(len)) |i| {
            const enemy_spawn_param_base = try (components.getValue(i, &scope, .fo(g.sdk))) orelse continue;
            var type_def = enemy_spawn_param_base.getTypeDefinition(.fo(g.sdk)) orelse
                return error.EnemySpawnParamBaseTypeNotFound;

            const component: *interop.ViaComponent = @ptrCast(enemy_spawn_param_base.raw);
            const owner = try GameObject.init(&g.interop_cache, .fo(g.sdk), component.getOwner());
            const game_obj_name_sys_str = try owner.call(.get_Name, &scope, .fo(g.sdk), .{});
            const game_obj_name = try std.unicode.utf16LeToUtf8AllocZ(arena, game_obj_name_sys_str.data);

            const context_id = try EnemySpawnParamBaseT.scoped(&scope).call(
                enemy_spawn_param_base,
                "get_ManagedContextID()",
                re.sdk.ManagedObject,
                .fo(g.sdk),
                .{},
            );
            var max_hp: i32 = 0;
            const context_ref = try g.character_manager.call(.getContextRef, &scope, .fo(g.sdk), .{context_id});
            if (context_ref) |context| {
                type_def = context.getTypeDefinition(.fo(g.sdk)) orelse type_def;
                const hit_point = try CharacterContextT.scoped(&scope).call(
                    context,
                    "get_HitPoint",
                    re.sdk.ManagedObject,
                    .fo(g.sdk),
                    .{},
                );
                max_hp = try scope.callMethod(
                    hit_point,
                    "get_CurrentMaximumHitPoint()",
                    i32,
                    .fo(g.sdk),
                    .{},
                );
            }

            errdefer log.err("failed get_SpawnData", .{});
            const spawn_data = try EnemySpawnParamBaseT.scoped(&scope).call(
                enemy_spawn_param_base,
                "get_SpawnData()",
                re.sdk.ManagedObject,
                .fo(g.sdk),
                .{},
            );
            errdefer log.err("failed get_Position", .{});
            var position: @Vector(3, f32) = try scope.callMethod(
                spawn_data,
                "get_Position()",
                @Vector(3, f32),
                .fo(g.sdk),
                .{},
            );

            var role_actions: std.ArrayList(EnemyRoleAction) = .empty;
            defer role_actions.deinit(arena);

            errdefer log.err("failed get_EnemySettings", .{});
            const enemy_settings = try EnemySpawnParamBaseT.scoped(&scope).call(
                enemy_spawn_param_base,
                "get_EnemySettings()",
                re.sdk.ManagedObject,
                .fo(g.sdk),
                .{},
            );
            errdefer log.err("failed get_RoleSettings", .{});
            const role_settings = try scope.callMethod(
                enemy_settings,
                "get_RoleSettings()",
                re.sdk.ManagedObject,
                .fo(g.sdk),
                .{},
            );
            errdefer log.err("failed get_SpawnParamCoordData", .{});
            const coord_data = try scope.callMethod(
                role_settings,
                "get_SpawnParamCoordData()",
                re.sdk.ManagedObject,
                .fo(g.sdk),
                .{},
            );
            const coord_data_position = try scope.callMethod(
                coord_data,
                "get_Position()",
                @Vector(3, f32),
                .fo(g.sdk),
                .{},
            );
            if (coord_data_position[0] != position[0] or
                coord_data_position[1] != position[1] or
                coord_data_position[2] != position[2])
            {
                log.warn("SpawnData has position: {} but saved cood Position: {}", .{ position, coord_data_position });
                position = coord_data_position;
            }
            const role_action_pool = try scope.callMethod(
                role_settings,
                "get_ActionPool()",
                re.sdk.ManagedObject,
                .fo(g.sdk),
                .{},
            );
            const role_actions_list = try scope.callMethod(
                role_action_pool,
                "get_RoleActions()",
                re.sdk.ManagedObject,
                .fo(g.sdk),
                .{},
            );
            const role_actions_items = try scope.getField(
                role_actions_list,
                "_items",
                SystemArray,
                .fo(g.sdk),
            );
            const role_actions_len = try role_actions_items.getLength(&scope, .fo(g.sdk));
            for (0..@intCast(role_actions_len)) |j| {
                const role_action = (try role_actions_items.getValue(j, &scope, .fo(g.sdk))) orelse continue;
                const resume_point = scope.getField(role_action, "_ResumePoint", @Vector(3, f32), .fo(g.sdk)) catch continue;
                const resume_yaw = scope.getField(role_action, "_ResumeYaw", f32, .fo(g.sdk)) catch continue;
                const return_point = scope.getField(role_action, "_ReturnPoint", @Vector(3, f32), .fo(g.sdk)) catch continue;
                const return_yaw = scope.getField(role_action, "_ReturnYaw", f32, .fo(g.sdk)) catch continue;

                try role_actions.append(arena, .{
                    .index = j,
                    .resume_point = resume_point,
                    .resume_yaw = resume_yaw,
                    .return_point = return_point,
                    .return_yaw = return_yaw,
                });
            }

            try self.enemies.append(arena, .{
                .enemy_type_name = getEnemyTypeName(type_def, max_hp),
                .game_obj_name = game_obj_name,
                .base = enemy_spawn_param_base,
                .position = position,
                .role_actions = try role_actions.toOwnedSlice(arena),
            });
        }
        log.info("Found {} EnemyParamSpawns", .{self.enemies.items.len});
    }

    fn spawn(self: *SceneEnemyManagement, scope: *interop.Scope, enemy: EnemySpawnParamDetails, params: EnemySpawnParams) !void {
        const arena = self.arena.allocator();

        // const SceneT = try g.interop_cache.resolve("via.Scene", g.tdb, .fo(g.sdk));
        // const FolderT = try g.interop_cache.resolve("via.Folder", g.tdb, .fo(g.sdk));
        const EnemySpawnParamBaseT = try g.interop_cache.resolve("app.EnemySpawnParamBase", g.tdb, .fo(g.sdk));
        const ContextIDT = try g.interop_cache.resolve("app.ContextID", g.tdb, .fo(g.sdk));
        const SystemGuidT = try g.interop_cache.resolve("System.Guid", g.tdb, .fo(g.sdk));

        const orig = enemy.base;

        const new_spawn_id = try SystemGuidT.scoped(scope).callStaticMethod(
            "NewGuid()",
            interop.ValueType,
            .fo(g.sdk),
            .{},
        );
        const new_spawn_context_id = ContextIDT.type_def_metadata.def.createInstance(.fo(g.sdk), .simplify) orelse
            return error.ContextIDCreationFailed;
        new_spawn_context_id.addRef(.fo(g.sdk));
        try ContextIDT.scoped(scope).call(
            new_spawn_context_id,
            ".ctor(System.Guid)",
            void,
            .fo(g.sdk),
            .{new_spawn_id},
        );

        const copy = try EnemySpawnParamBaseT.scoped(scope).call(
            orig,
            "MemberwiseClone()",
            re.sdk.ManagedObject,
            .fo(g.sdk),
            .{},
        );
        copy.addRef(.fo(g.sdk));
        // this Id what's lets us spawn multiple enemies with the same spawn params...
        try EnemySpawnParamBaseT.scoped(scope).set(copy, ._SpawnID, .fo(g.sdk), new_spawn_id);

        const spawn_data_orig = try EnemySpawnParamBaseT.scoped(scope).call(
            copy,
            "get_SpawnData()",
            re.sdk.ManagedObject,
            .fo(g.sdk),
            .{},
        );
        const copied_spawn_data = try scope.callMethod(
            spawn_data_orig,
            "MemberwiseClone()",
            re.sdk.ManagedObject,
            .fo(g.sdk),
            .{},
        );
        copied_spawn_data.addRef(.fo(g.sdk));
        errdefer {
            log.err("set_SpawnData failed", .{});
            copied_spawn_data.release(.fo(g.sdk));
        }
        try EnemySpawnParamBaseT.scoped(scope).call(
            copy,
            "set_SpawnData(app.CharacterSpawnData)",
            void,
            .fo(g.sdk),
            .{copied_spawn_data},
        );
        try scope.callMethod(
            copied_spawn_data,
            "set_ContextID(app.ContextID)",
            void,
            .fo(g.sdk),
            .{new_spawn_context_id},
        );
        try scope.callMethod(
            copied_spawn_data,
            "set_Position(via.vec3)",
            void,
            .fo(g.sdk),
            .{params.position},
        );
        try EnemySpawnParamBaseT.scoped(scope).call(
            copy,
            "set_SpawnContextID(app.ContextID)",
            void,
            .fo(g.sdk),
            .{new_spawn_context_id},
        );

        const copied_enemy_settings = try getFieldCopyAndSet(
            scope,
            copied_spawn_data,
            ._EnemySettings,
        );
        log.debug("copied_enemy_settings: {*}", .{copied_enemy_settings.raw});
        const copied_role_settings = try getFieldCopyAndSet(
            scope,
            copied_enemy_settings,
            ._RoleSettings,
        );
        log.debug("copied_role_settings: {*}", .{copied_role_settings.raw});
        const copied_coord_data = try getMemberCopyAndSet(
            scope,
            copied_role_settings,
            "get_SpawnParamCoordData()",
            "set_SpawnParamCoordData",
        );
        try scope.callMethod(
            copied_coord_data,
            "set_Position(via.vec3)",
            void,
            .fo(g.sdk),
            .{params.position},
        );
        log.debug("copied_coord_data: {*}", .{copied_coord_data.raw});

        const copied_role_action_pool = try getFieldCopyAndSet(
            scope,
            copied_role_settings,
            ._ActionPool,
        );
        log.debug("copied_role_action_pool: {*}", .{copied_role_action_pool.raw});

        const role_actions_list = try scope.callMethod(
            copied_role_action_pool,
            "get_RoleActions()",
            re.sdk.ManagedObject,
            .fo(g.sdk),
            .{},
        );
        const role_actions_orig = try scope.getField(
            role_actions_list,
            "_items",
            interop.SystemArray,
            .fo(g.sdk),
        );
        const role_actions_type_def = role_actions_list.getTypeDefinition(.fo(g.sdk)) orelse
            return error.RoleActionsTypeDefNotFound;
        const copied_role_actions_list = role_actions_type_def.createInstance(.fo(g.sdk), .simplify) orelse
            return error.FailedToCreateRoleActions;
        copied_role_actions_list.addRef(.fo(g.sdk));
        try scope.callMethod(
            copied_role_action_pool,
            "set_RoleActions",
            void,
            .fo(g.sdk),
            .{copied_role_actions_list},
        );
        log.debug("copied_role_actions_list: {*}", .{copied_role_actions_list.raw});
        errdefer {
            if (copied_role_actions_list.getRefCount(.fo(g.sdk)) > 0)
                copied_role_actions_list.release(.fo(g.sdk));
        }
        try scope.callMethod(copied_role_actions_list, ".ctor()", void, .fo(g.sdk), .{});
        const role_actions_len = try role_actions_orig.getLength(scope, .fo(g.sdk));
        var copied_role_actions: std.ArrayList(re.sdk.ManagedObject) = .empty;
        defer copied_role_actions.deinit(arena);
        for (0..@intCast(role_actions_len)) |i| {
            const role_action_orig = (try role_actions_orig.getValue(i, scope, .fo(g.sdk))) orelse continue;
            const copied_role_action = try scope.callMethod(
                role_action_orig,
                "MemberwiseClone()",
                re.sdk.ManagedObject,
                .fo(g.sdk),
                .{},
            );
            copied_role_action.addRef(.fo(g.sdk));
            errdefer {
                log.err("[{}] Add failed", .{i});
                if (copied_role_action.getRefCount(.fo(g.sdk)) > 0)
                    copied_role_action.release(.fo(g.sdk));
            }
            try scope.callMethod(copied_role_actions_list, "Add", void, .fo(g.sdk), .{copied_role_action});

            for (params.role_actions) |param_role_action| {
                if (param_role_action.index != i) continue;
                try scope.setField(copied_role_action, "_ResumePoint", .fo(g.sdk), param_role_action.resume_point);
                try scope.setField(copied_role_action, "_ResumeYaw", .fo(g.sdk), param_role_action.resume_yaw);
                try scope.setField(copied_role_action, "_ReturnPoint", .fo(g.sdk), param_role_action.return_point);
                try scope.setField(copied_role_action, "_ReturnYaw", .fo(g.sdk), param_role_action.return_yaw);
            }

            try copied_role_actions.append(arena, copied_role_action);
        }

        // try EnemySpawnParamBaseT.scoped(scope).call(
        //     copy,
        //     "setupSpawnData(app.CharacterSpawnData)",
        //     void,
        //     .fo(g.sdk),
        //     .{copied_spawn_data},
        // );
        // this and on the spawn data needs to be set
        try EnemySpawnParamBaseT.scoped(scope).set(
            copy,
            ._EnemySettings,
            .fo(g.sdk),
            copied_enemy_settings,
        );
        // this creates a new CharacterContext
        try EnemySpawnParamBaseT.scoped(scope).call(copy, "awake()", void, .fo(g.sdk), .{});

        errdefer log.err("requestSpawn failed", .{});
        //try EnemySpawnParamBaseT.scoped(scope).call(copy, "requestSpawn()", void, .fo(g.sdk), .{});
        try EnemySpawnParamBaseT.scoped(scope).call(copy, "requestRestoreSpawn()", void, .fo(g.sdk), .{});
        try EnemySpawnParamBaseT.scoped(scope).call(copy, "readySpawn(System.Boolean)", void, .fo(g.sdk), .{true});
        try EnemySpawnParamBaseT.scoped(scope).call(copy, "permitSpawn(System.Boolean)", void, .fo(g.sdk), .{true});

        try self.spawned_enemies.append(arena, .{
            .copied_base = copy,
            .copied_spawn_data = copied_spawn_data,
            .copied_enemy_settings = copied_enemy_settings,
            .copied_role_settings = copied_role_settings,
            .copied_coord_data = copied_coord_data,
            .copied_role_action_pool = copied_role_action_pool,
            .copied_role_actions_list = copied_role_actions_list,
            .copied_role_actions = try copied_role_actions.toOwnedSlice(arena),
            .new_spawn_context_id = new_spawn_context_id,
        });

        log.info("spawned enemy: {*}, base: {*}", .{ copy.raw, enemy.base.raw });
    }

    pub fn queueSpawn(self: *SceneEnemyManagement, enemy: EnemySpawnParamDetails, params: EnemySpawnParams) !void {
        try self.mutex.lock(g.io);
        defer self.mutex.unlock(g.io);

        const arena = self.arena.allocator();
        try self.spawn_queue.pushBack(arena, .{ enemy, params });
    }

    fn spawnNext(self: *SceneEnemyManagement) !void {
        try self.mutex.lock(g.io);
        defer self.mutex.unlock(g.io);

        if (self.spawn_queue.popFront()) |item| {
            var scope = g.interop_cache.newScope(self.arena.allocator());
            defer scope.deinit();

            const enemy = item.@"0";
            const params = item.@"1";
            try self.spawn(&scope, enemy, params);
        }
    }

    fn reset(self: *SceneEnemyManagement) void {
        for (self.spawned_enemies.items) |enemy| {
            safeFreeManagedObject(enemy.copied_base);
            safeFreeManagedObject(enemy.copied_spawn_data);
            safeFreeManagedObject(enemy.copied_enemy_settings);
            safeFreeManagedObject(enemy.copied_role_settings);
            safeFreeManagedObject(enemy.copied_coord_data);
            safeFreeManagedObject(enemy.copied_role_action_pool);
            safeFreeManagedObject(enemy.copied_role_actions_list);
            for (enemy.copied_role_actions) |action| {
                safeFreeManagedObject(action);
            }
            safeFreeManagedObject(enemy.new_spawn_context_id);
        }
        _ = self.arena.reset(.retain_capacity);
        self.enemies = .empty;
        self.spawned_enemies = .empty;
        self.current_scene_name = null;

        self.mutex.lockUncancelable(g.io);
        self.mutex.unlock(g.io);
        self.spawn_queue = .empty;
    }
};

// mainly map/populate collections which changes per-level wise here
pub fn new() !void {
    g.interop_cache.resetDiagnostics();
    defer g.interop_cache.resetDiagnostics();

    try g.scene_enemy_management.update();

    // we first need to make sure the player is initialized, this will ensure that per-level collections are set
    g.player = try .init();

    log.info("Collected item-pickups: {}", .{g.item_pickups.collection.items.len});
    try g.item_pickups.mapPickupsWithItemId();

    log.debug("Updating level flow managed objects...", .{});
    try g.level_flow_managed_objects.update();
    log.info("Collected level flow managed objects: {}", .{g.level_flow_managed_objects.collection.items.len});
    const LevelFlowGameJumpActionParamT = try managed_types.LFBTA_FSM_GameJumpAction_LevelFlowGameJumpActionParam
        .Runtime
        .get(&g.interop_cache, .fo(g.sdk));
    const flows = try g.level_flow_managed_objects.getWithChildComponentType(LevelFlowGameJumpActionParamT.metadata.type_def);
    log.info("Found game flows: {}", .{flows.len});
    {
        var scope = g.interop_cache.newScope(g.allocator);
        defer scope.deinit();

        for (flows) |flow| {
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

            var child_component = component.childComponent();
            while (child_component) |child| : (child_component = child.childComponent()) {
                if (child == component) {
                    break;
                }

                const child_mo = re.sdk.ManagedObject{ .raw = @ptrCast(@alignCast(child)) };
                if (!child_mo.isManagedObject(.fo(g.sdk))) {
                    log.debug("Found non-managed-object child component: 0x{x}", .{@intFromPtr(child)});
                    continue;
                }
                const type_def = child_mo.getTypeDefinition(.fo(g.sdk)) orelse continue;
                const type_name = try type_def.getFullNameAlloc(.fo(g.sdk), scope.arena.allocator());
                log.debug("  Child Component: 0x{x}, Type: {s}", .{
                    @intFromPtr(child),
                    type_name,
                });
            }
        }
    }

    try g.player.?.checkInventory();
    try g.player.?.checkFileInventory();
    try g.player.?.checkObjectives();
    try g.player.?.checkGameJumps(flows);
}

pub fn reset() void {
    g.items.reset();
    g.item_pickups.reset();
    g.files.reset();
    g.level_flow_managed_objects.reset();
    g.btree_management.reset();

    ui.reset();

    const player = &(g.player orelse return);
    player.deinit();

    g.player = null;
}

// we populate the lists/maps when we need to collect them from a singleton
pub fn staticNew() !void {
    log.debug("Repopulating items...", .{});
    try g.items.repopulate();
    log.info("Collected items: {}", .{g.items.items_cache.count()});

    log.debug("Repopulating files...", .{});
    try g.files.repopulate();
    log.info("Collected files: {}", .{g.files.filesSlice().len});
}

fn tdbGetMethod(tdb: re.sdk.Tdb, comptime type_name: [:0]const u8, comptime method_sig: [:0]const u8) !?*interop.MethodMetadata {
    const type_def = tdb.findType(.fo(g.sdk), type_name) orelse return null;
    const metadata = try g.interop_cache.getOrCacheMethodMetadata(.fo(g.sdk), type_def, method_sig);
    return metadata;
}

fn onStart() !void {
    g.api.lockLua();
    defer g.api.unlockLua();

    try staticNew();
}

fn onMainGameSwitchScene() !void {
    g.api.lockLua();
    defer g.api.unlockLua();

    log.debug("Player initializing...", .{});

    try new();
}

fn onNewSceneRequest() void {
    g.api.lockLua();
    defer g.api.unlockLua();

    log.debug("NewScene Requested resetting...", .{});

    reset();
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

pub fn test1() !void {
    if (g.scene_enemy_management.enemies.items.len == 0) {
        log.info("No enemies to found", .{});
        return;
    }

    if (g.scene_enemy_management.current_scene_name) |name| {
        log.info("Current scene: {s}", .{name});
    }

    var scope = g.interop_cache.newScope(g.allocator);
    defer scope.deinit();

    const enemy = g.scene_enemy_management.enemies.items[0];
    log.info("Spawning enemy: {s}", .{enemy.enemy_type_name});
    var role_actions = [_]EnemyRoleAction{
        .{
            .index = 0,
            .resume_point = .{ 4.184, 2.277, 37.947 },
            .resume_yaw = -90.0,
            .return_point = .{ -2.417, 2.277, 36.349 },
            .return_yaw = -270.0,
        },
        .{
            .index = 1,
            .resume_point = .{ 4.184, 2.277, 37.947 },
            .resume_yaw = -90.0,
            .return_point = .{ -2.417, 2.277, 36.349 },
            .return_yaw = -270.0,
        },
    };
    try g.scene_enemy_management.spawn(&scope, enemy, .{
        .position = .{ 4.184, 2.277, 37.947 },
        .role_actions = &role_actions,
    });
}

pub fn test2() !void {
    var scope = g.interop_cache.newScope(g.allocator);
    defer scope.deinit();
    const arena = scope.arena.allocator();
    // const CharacterKindIDT = try g.interop_cache.resolve("app.CharacterKindID", g.tdb, .fo(g.sdk));
    // const character_kind_id = try CharacterKindIDT.scoped(&scope).getStatic(.cp_B002, re.sdk.ManagedObject, .fo(g.sdk));
    // const char_context_func = try g.character_manager.call(.getCharacterContextFactory, &scope, .fo(g.sdk), .{character_kind_id});
    // const char_context = try scope.callMethod(char_context_func, "Invoke", re.sdk.ManagedObject, .fo(g.sdk), .{});
    // char_context.addRef(.fo(g.sdk));
    // const type_def = char_context.getTypeDefinition(.fo(g.sdk)) orelse return error.TypeDefinitionNotFound;
    // const type_name = try type_def.getFullNameAlloc(.fo(g.sdk), arena);
    // log.debug("Found char_context: 0x{x} ({s})", .{ @intFromPtr(char_context.raw), type_name });

    const SceneManagerT = try g.interop_cache.resolve("via.SceneManager", g.tdb, .fo(g.sdk));
    const SceneT = try g.interop_cache.resolve("via.Scene", g.tdb, .fo(g.sdk));
    const FolderT = try g.interop_cache.resolve("via.Folder", g.tdb, .fo(g.sdk));
    // const PrefabT = try g.interop_cache.resolve("via.Prefab", g.tdb, .fo(g.sdk));
    const ContextIDT = try g.interop_cache.resolve("app.ContextID", g.tdb, .fo(g.sdk));
    const SystemGuidT = try g.interop_cache.resolve("System.Guid", g.tdb, .fo(g.sdk));
    // const GameObjectT = try g.interop_cache.resolve("via.GameObject", g.tdb, .fo(g.sdk));

    // const resource_mgr = re.sdk.getResourceManager(.fo(g.sdk)) orelse return error.ResourceManagerNotFound;
    // const resource = resource_mgr.createResource(.fo(g.sdk), "via.Prefab", "natives/stm/GameAssets/Character/Spawn/cp_B000SpawnParam.pfb") orelse return error.ResourceCreationFailed;
    // resource.addRef(.fo(g.sdk));
    // log.debug("Found resource: 0x{x}", .{@intFromPtr(resource.raw)});

    const scene_manager = re.sdk.getNativeSingleton(.fo(g.sdk), "via.SceneManager") orelse return error.SceneManagerNotFound;
    const type_name = try SceneManagerT.type_def_metadata.def.getFullNameAlloc(.fo(g.sdk), arena);
    log.debug("Found scene_manager: 0x{x} ({s})", .{ @intFromPtr(scene_manager), type_name });

    const current_scene = try SceneManagerT
        .scoped(&scope)
        .call(scene_manager, "get_CurrentScene", re.sdk.ManagedObject, .fo(g.sdk), .{});
    log.debug("Found current_scene: 0x{x}", .{@intFromPtr(current_scene.raw)});

    const enemy_spawn_base_param_type = re.sdk.typeof(.fo(g.sdk), "app.EnemySpawnParamBase") orelse return error.EnemySpawnParamBaseNotFound;
    const enemy_base_components = try SceneT
        .scoped(&scope)
        .call(current_scene, "findComponents(System.Type)", interop.SystemArray, .fo(g.sdk), .{enemy_spawn_base_param_type});
    const len = try enemy_base_components.getLength(&scope, .fo(g.sdk));
    log.debug("Found enemy_base_components: 0x{x}, {}", .{ @intFromPtr(enemy_base_components.instance.managed.raw), len });

    // const player_pos = try g.player.?.player_context.call(.get_Position, &scope, .fo(g.sdk), .{});
    // log.debug("Found player_pos: {}", .{player_pos});

    const new_spawn_id = try SystemGuidT.scoped(&scope).callStaticMethod(
        "NewGuid()",
        interop.ValueType,
        .fo(g.sdk),
        .{},
    );
    log.debug("\nnew_spawn_guid: {any}", .{new_spawn_id.data[0x10..]});

    const new_spawn_context_id = ContextIDT.type_def_metadata.def.createInstance(.fo(g.sdk), .simplify) orelse return error.ContextIDCreationFailed;
    new_spawn_context_id.addRef(.fo(g.sdk));
    try ContextIDT.scoped(&scope).call(new_spawn_context_id, ".ctor(System.Guid)", void, .fo(g.sdk), .{new_spawn_id});
    new_spawn_context_id.addRef(.fo(g.sdk));
    log.debug("Created new_managed_context_id: 0x{x}", .{@intFromPtr(new_spawn_context_id.raw)});

    for (0..@intCast(len)) |i| {
        const enemy_spawn_param_base_orig = (try enemy_base_components.getValue(i, &scope, .fo(g.sdk))) orelse continue;
        const enemy_spawn_param_base = try scope.callMethod(enemy_spawn_param_base_orig, "MemberwiseClone()", re.sdk.ManagedObject, .fo(g.sdk), .{});
        enemy_spawn_param_base.addRef(.fo(g.sdk));

        const orig_spawn_id = try scope.callMethod(enemy_spawn_param_base, "get_SpawnID()", interop.ValueType, .fo(g.sdk), .{});
        log.debug("orig_spawn_id: {any}", .{orig_spawn_id.data});

        try scope.setField(enemy_spawn_param_base, "_SpawnID", .fo(g.sdk), new_spawn_id);
        const spawn_id = try scope.callMethod(enemy_spawn_param_base, "get_SpawnID()", interop.ValueType, .fo(g.sdk), .{});
        log.debug("spawn_id: {any}", .{spawn_id.data});

        const component: *interop.ViaComponent = @ptrCast(enemy_spawn_param_base.raw);

        const game_obj = try GameObject.init(&g.interop_cache, .fo(g.sdk), component.getOwner());
        log.debug("owner: 0x{x}", .{@intFromPtr(game_obj.managed.raw)});
        // component.setOwner(null);

        const game_obj_name_sys_str = try game_obj.call(.get_Name, &scope, .fo(g.sdk), .{});
        const game_obj_name = try std.unicode.utf16LeToUtf8AllocZ(arena, game_obj_name_sys_str.data);

        const folder = try game_obj.call(.get_FolderSelf, &scope, .fo(g.sdk), .{});
        const folder_path_str = try FolderT.scoped(&scope).call(folder, "get_Path()", interop.SystemStringView, .fo(g.sdk), .{});
        const folder_path = try std.unicode.utf16LeToUtf8AllocZ(arena, folder_path_str.data);

        const context_id = try scope.callMethod(
            enemy_spawn_param_base_orig,
            "get_ManagedContextID()",
            re.sdk.ManagedObject,
            .fo(g.sdk),
            .{},
        );
        const context_ref = try g.character_manager.call(.getContextRef, &scope, .fo(g.sdk), .{context_id});
        if (context_ref) |context| {
            const type_def = context.getTypeDefinition(.fo(g.sdk)) orelse continue;
            const hit_point = try scope.callMethod(
                context,
                "get_HitPoint",
                re.sdk.ManagedObject,
                .fo(g.sdk),
                .{},
            );
            const max_hp = try scope.callMethod(
                hit_point,
                "get_CurrentMaximumHitPoint()",
                i32,
                .fo(g.sdk),
                .{},
            );
            const name = getEnemyTypeName(type_def, max_hp);
            if (std.ascii.findIgnoreCase(name, "Cleaner") == null) {
                continue;
            }
            log.debug("===test2===Spawning enemy: {s}", .{name});
        } else {
            continue;
        }

        // const game_obj_new = try GameObjectT.scoped(&scope).callStaticMethod(
        //     "create(System.String, via.Folder)",
        //     re.sdk.ManagedObject,
        //     .fo(g.sdk),
        //     .{ game_obj_name, folder },
        // );
        // game_obj_new.addRef(.fo(g.sdk));
        // component.setOwner(game_obj_new);
        // log.debug("created game object: 0x{x}", .{@intFromPtr(game_obj_new.raw)});
        // const typedef = enemy_spawn_param_base.getTypeDefinition(.fo(g.sdk)) orelse return error.TypeDefinitionNotFound;
        // const enemy_spawn_param_base_runtime_type = typedef.getRuntimeType(.fo(g.sdk)) orelse return error.RuntimeTypeNotFound;

        const spawn_data_orig = try scope.callMethod(enemy_spawn_param_base, "get_SpawnData()", re.sdk.ManagedObject, .fo(g.sdk), .{});
        const spawn_data = try scope.callMethod(spawn_data_orig, "MemberwiseClone()", re.sdk.ManagedObject, .fo(g.sdk), .{});
        spawn_data.addRef(.fo(g.sdk));

        try scope.callMethod(
            spawn_data,
            "set_ContextID(app.ContextID)",
            void,
            .fo(g.sdk),
            .{new_spawn_context_id},
        );

        log.debug("cloned spawn data and updated context id", .{});

        // enemy_spawn_param_base = try GameObjectT.scoped(&scope).call(game_obj_new, "createComponent(System.Type)", re.sdk.ManagedObject, .fo(g.sdk), .{enemy_spawn_param_base_runtime_type});

        try scope.callMethod(
            enemy_spawn_param_base,
            "setupSpawnData(app.CharacterSpawnData)",
            void,
            .fo(g.sdk),
            .{spawn_data},
        );

        log.debug("setup new spawn data", .{});

        // const sd_context_id = try scope.callMethod(spawn_data, "get_ContextID()", re.sdk.ManagedObject, .fo(g.sdk), .{});
        // const spawn_data_ref_opt = try g.character_manager.call(.getSpawnDataRef, &scope, .fo(g.sdk), .{sd_context_id});
        // if (spawn_data_ref_opt != null) continue;
        try scope.callMethod(
            enemy_spawn_param_base,
            "set_SpawnContextID(app.ContextID)",
            void,
            .fo(g.sdk),
            .{new_spawn_context_id},
        );

        const managed_context_id = try scope.callMethod(enemy_spawn_param_base, "get_ManagedContextID()", re.sdk.ManagedObject, .fo(g.sdk), .{});
        const is_used = try g.character_manager.call(.isUsedContext, &scope, .fo(g.sdk), .{managed_context_id});
        log.debug(
            "[{}] folder: 0x{x}({s}):\n  enemy_base_component: 0x{x}, name: {s}, is_used: {}, context_id: {*}",
            .{
                i,
                @intFromPtr(folder.raw),
                folder_path,
                @intFromPtr(component),
                game_obj_name,
                is_used,
                managed_context_id.raw,
            },
        );

        const spawn_pos = try scope.callMethod(
            spawn_data,
            "get_Position()",
            @Vector(3, f32),
            .fo(g.sdk),
            .{},
        );
        log.debug("spawn_pos: {}", .{spawn_pos});

        try scope.callMethod(
            spawn_data,
            "set_Position(via.vec3)",
            void,
            .fo(g.sdk),
            .{@Vector(3, f32){ 4.184, 2.277, 37.947 }},
        );

        const new_spawn_pos = try scope.callMethod(
            spawn_data,
            "get_Position()",
            @Vector(3, f32),
            .fo(g.sdk),
            .{},
        );
        log.debug("new_spawn_pos: {}", .{new_spawn_pos});

        try scope.callMethod(
            enemy_spawn_param_base,
            "awake()",
            void,
            .fo(g.sdk),
            .{},
        );

        log.debug("awoken enemy_spawn_param_base", .{});
        const managed_context_id_after = try scope.callMethod(enemy_spawn_param_base, "get_ManagedContextID()", re.sdk.ManagedObject, .fo(g.sdk), .{});
        const is_used_after = try g.character_manager.call(.isUsedContext, &scope, .fo(g.sdk), .{managed_context_id});
        log.debug("managed_context_id_after: {*}, is_used_after: {}", .{ managed_context_id_after.raw, is_used_after });

        const montage_id = try scope.callMethod(enemy_spawn_param_base, "get_ManagedMontageID()", interop.ValueType, .fo(g.sdk), .{});
        log.debug("montage_id_type_def: 0x{x}", .{@intFromPtr(montage_id.type_def.raw)});

        const enemy_settings = try scope.callMethod(enemy_spawn_param_base, "get_EnemySettings()", re.sdk.ManagedObject, .fo(g.sdk), .{});
        const orig_enemy_settings = try scope.callMethod(enemy_spawn_param_base_orig, "get_EnemySettings()", re.sdk.ManagedObject, .fo(g.sdk), .{});
        log.debug("enemy_settings: {*} orig_enemy_settings: {*}", .{ enemy_settings.raw, orig_enemy_settings.raw });
        const role_settings = try scope.callMethod(enemy_settings, "get_RoleSettings()", re.sdk.ManagedObject, .fo(g.sdk), .{});
        log.debug("role_settings: {*}", .{role_settings.raw});

        // get_SpawnParamCoordData()
        const coord_data = try scope.callMethod(role_settings, "get_SpawnParamCoordData()", re.sdk.ManagedObject, .fo(g.sdk), .{});
        log.debug("coord_data: {*}", .{coord_data.raw});
        try scope.callMethod(coord_data, "set_Position(via.vec3)", void, .fo(g.sdk), .{@Vector(3, f32){ 4.184, 2.277, 37.947 }});

        const role_action_pool = try scope.callMethod(role_settings, "get_ActionPool()", re.sdk.ManagedObject, .fo(g.sdk), .{});
        log.debug("role_action_pool: {*}", .{role_action_pool.raw});
        const role_actions = try scope.callMethod(role_action_pool, "get_RoleActions()", re.sdk.ManagedObject, .fo(g.sdk), .{});
        log.debug("role_actions: {*}", .{role_actions.raw});
        const role_actions_items = try scope.getField(role_actions, "_items", interop.SystemArray, .fo(g.sdk));

        const role_actions_len = try role_actions_items.getLength(&scope, .fo(g.sdk));
        log.debug("role_actions_len: {}", .{role_actions_len});

        for (0..@intCast(role_actions_len)) |role_action_idx| {
            const role_action = try role_actions_items.getValue(role_action_idx, &scope, .fo(g.sdk)) orelse continue;
            log.debug("role_action: {*}", .{role_action.raw});
            try scope.setField(role_action, "_ResumePoint", .fo(g.sdk), @Vector(3, f32){ 4.184, 2.277, 37.947 });
            try scope.setField(role_action, "_ResumeYaw", .fo(g.sdk), -90.0);
            try scope.setField(role_action, "_ReturnPoint", .fo(g.sdk), @Vector(3, f32){ -2.417, 2.277, 36.349 });
            try scope.setField(role_action, "_ReturnYaw", .fo(g.sdk), -270.0);
        }

        //try scope.callMethod(enemy_spawn_param_base, "requestSpawn()", void, .fo(g.sdk), .{});
        try scope.callMethod(enemy_spawn_param_base, "requestRestoreSpawn()", void, .fo(g.sdk), .{});
        try scope.callMethod(enemy_spawn_param_base, "readySpawn(System.Boolean)", void, .fo(g.sdk), .{true});
        try scope.callMethod(enemy_spawn_param_base, "permitSpawn(System.Boolean)", void, .fo(g.sdk), .{true});

        // try g.character_manager.call(.requestSpawn, &scope, .fo(g.sdk), .{
        //     managed_context_id,
        //     character_kind_id,
        //     montage_id,
        //     1,
        //     true,
        //     managed_types.CharacterUsePurposeFlag.default,
        // });

        const character_kind_id = try scope.callMethod(enemy_spawn_param_base, "get_ManagedCharacterKindID()", re.sdk.ManagedObject, .fo(g.sdk), .{});
        log.debug("spawned character_kind_id: 0x{x}", .{@intFromPtr(character_kind_id.raw)});

        break;
    }
    // const folders = try SceneT
    //     .scoped(&scope)
    //     .call(current_scene, "findFolder", re.sdk.ManagedObject, .fo(g.sdk), .{@as([:0]const u8, "")});
    // log.debug("Found folders: 0x{x}", .{@intFromPtr(folders.raw)});
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

    // The BehaviorTree dispatcher, dispatches in multiple threaded manner, we need to start/queue/remove BehaviorTree actions in the hook because
    // the function `updateProgressiveNumber` gets called after or before each dispatch frame, so we will be on the same thread as the dispatcher.
    // Pre Application entry hook on `UpdateBehavior` function might also work, just didn't test it.
    _ = g.level_flow_manager.runtime.getMethod(.updateProgressiveNumber).addHook(
        .fo(g.sdk.safe().functions),
        struct {
            fn func(_: ?[]?*anyopaque, _: ?[]re.sdk.TypeDefinition, _: u64) re.api.HookCall {
                g.btree_management.performSingleAction() catch |e| {
                    log.err("Failed to perform behavior tree action: {}", .{e});
                };
                g.scene_enemy_management.spawnNext() catch |e| {
                    log.err("Failed to spawn next enemy: {}", .{e});
                };
                return .call_original;
            }
        }.func,
        null,
        false,
    );

    _ = g.level_flow_manager.runtime.getMethod(.updateManagedObject).addHook(
        .fo(g.sdk.safe().functions),
        struct {
            fn func(args_opt: ?[]?*anyopaque, _: ?[]re.sdk.TypeDefinition, _: u64) re.api.HookCall {
                const args = args_opt orelse return .call_original;
                if (args.len < 3) return .call_original;

                const this_ptr = args[2] orelse return .call_original;
                const this_mo: re.sdk.ManagedObject = .{ .raw = @ptrCast(@alignCast(this_ptr)) };
                const this = managed_types.LevelFlowChangeRequest.init(&g.interop_cache, .fo(g.sdk), this_mo) catch |e| {
                    log.err("Error in LevelFlowManagedObject init: {}", .{e});
                    return .call_original;
                };

                g.api.lockLua();
                defer g.api.unlockLua();

                var scope = g.interop_cache.newScope(g.allocator);
                defer scope.deinit();

                const name_hash = this.call(.get_NameHash, &scope, .fo(g.sdk), .{}) catch return .call_original;
                const change_number = this.call(.get_ChangeNumber, &scope, .fo(g.sdk), .{}) catch return .call_original;
                const on_complete = this.get(.OnComplete, &scope, .fo(g.sdk)) catch return .call_original;
                if (on_complete) |callback| {
                    log.debug("LevelFlowChangeRequest: NameHash: {}, ChangeNumber: {}, Callback: 0x{x}", .{
                        name_hash,
                        change_number,
                        @intFromPtr(callback.raw),
                    });
                } else {
                    log.debug("LevelFlowChangeRequest: NameHash: {}, ChangeNumber: {}", .{ name_hash, change_number });
                }

                return .call_original;
            }
        }.func,
        null,
        false,
    );

    if (is_debug) {
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
    }

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

    // const PlayerContextT = try PlayerContext.Runtime.getWithTdb(&g.interop_cache, .fo(g.sdk), g.tdb);
    // _ = PlayerContextT.getMethod(.onUnlinked).addHook(
    //     .fo(g.sdk.safe().functions),
    //     null,
    //     struct {
    //         fn func(_: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
    //             onPlayerUnlinked();
    //         }
    //     }.func,
    //     false,
    // );

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

    const CharacterManagerT = try CharacterManager.Runtime.getWithTdb(&g.interop_cache, .fo(g.sdk), g.tdb);
    _ = CharacterManagerT.getMethod(.notifyPlayerInitialized).addHook(
        .fo(g.sdk.safe().functions),
        null,
        struct {
            fn func(_: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                onMainGameSwitchScene() catch |e| {
                    log.err(
                        "Error notifyPlayerInitialized: {}, context: {s}",
                        .{ e, g.interop_cache.ownDiagnostics() catch "none" },
                    );
                };
            }
        }.func,
        false,
    );

    const SystemEventCallbackT = try SystemEventCallback.Runtime.getWithTdb(&g.interop_cache, .fo(g.sdk), g.tdb);
    _ = SystemEventCallbackT.getMethod(.onFinishTransitionForMainGame).addHook(
        .fo(g.sdk.safe().functions),
        null,
        struct {
            fn func(_: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                onMainGameSwitchScene() catch |e| {
                    log.err(
                        "Error onFinishTransitionForMainGame: {}, context: {s}",
                        .{ e, g.interop_cache.ownDiagnostics() catch "none" },
                    );
                };
            }
        }.func,
        false,
    );
    _ = SystemEventCallbackT.getMethod(.onSwitchedGameScene).addHook(
        .fo(g.sdk.safe().functions),
        null,
        struct {
            fn func(_: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                onMainGameSwitchScene() catch |e| {
                    log.err(
                        "Error onSwitchedGameScene: {}, context: {s}",
                        .{ e, g.interop_cache.ownDiagnostics() catch "none" },
                    );
                };
            }
        }.func,
        false,
    );
    _ = SystemEventCallbackT.getMethod(.onStartSceneTransition).addHook(
        .fo(g.sdk.safe().functions),
        null,
        struct {
            fn func(_: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                onNewSceneRequest();
            }
        }.func,
        false,
    );
    _ = g.scene_transition_manager.runtime.getMethod(.requestMainGameJumpCore).addHook(
        .fo(g.sdk.safe().functions),
        null,
        struct {
            fn func(_: ?*?*anyopaque, _: re.sdk.TypeDefinition, _: u64) void {
                onNewSceneRequest();
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
                    log.err(
                        "Error in UI draw: {}, context: {s}",
                        .{ e, g.interop_cache.ownDiagnostics() catch "none" },
                    );
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
