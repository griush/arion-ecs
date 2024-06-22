const std = @import("std");
const aecs = @This();

pub const Entity = u64;

const void_archetype_hash = std.math.maxInt(u64);

pub fn ComponentStorage(comptime Component: type) type {
    return struct {
        /// A reference to the total number of entities with the same type as is being stored here.
        total_rows: *usize,

        /// The actual densely stored component data.
        data: std.ArrayListUnmanaged(Component) = .{},

        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.data.deinit(allocator);
        }

        pub fn remove(self: *Self, row_index: u32) void {
            if (self.data.items.len > row_index) {
                _ = self.data.swapRemove(row_index);
            }
        }

        pub fn set(self: *Self, allocator: std.mem.Allocator, row_index: u32, component: Component) !void {
            if (self.data.items.len <= row_index) try self.data.appendNTimes(allocator, undefined, self.data.items.len + 1 - row_index);
            self.data.items[row_index] = component;
        }

        pub inline fn copy(dst: *Self, allocator: std.mem.Allocator, src_row: u32, dst_row: u32, src: *Self) !void {
            try dst.set(allocator, dst_row, src.get(src_row));
        }

        pub inline fn get(self: Self, row_index: u32) Component {
            return self.data.items[row_index];
        }
    };
}

pub const ErasedComponentStorage = struct {
    ptr: *anyopaque,

    deinit: *const fn (erased: *anyopaque, allocator: std.mem.Allocator) void,
    cloneType: *const fn (erased: ErasedComponentStorage, total_entities: *usize, allocator: std.mem.Allocator, retval: *ErasedComponentStorage) error{OutOfMemory}!void,
    copy: *const fn (dst_erased: *anyopaque, allocator: std.mem.Allocator, src_row: u32, dst_row: u32, src_erased: *anyopaque) error{OutOfMemory}!void,
    remove: *const fn (erased: *anyopaque, row: u32) void,

    // TODO: Possible fail here
    pub fn cast(ptr: *anyopaque, comptime Component: type) *ComponentStorage(Component) {
        return @ptrCast(@alignCast(ptr));
    }
};

pub const ArchetypeStorage = struct {
    allocator: std.mem.Allocator,

    hash: u64,

    entity_ids: std.ArrayListUnmanaged(Entity) = .{},
    components: std.StringArrayHashMapUnmanaged(ErasedComponentStorage),

    pub fn deinit(self: *ArchetypeStorage) void {
        for (self.components.values()) |erased| {
            erased.deinit(erased.ptr, self.allocator);
        }

        self.entity_ids.deinit(self.allocator);
        self.components.deinit(self.allocator);
    }

    pub fn new(self: *ArchetypeStorage, entity: Entity) !u32 {
        const new_row_index = self.entity_ids.items.len;
        try self.entity_ids.append(self.allocator, entity);
        return @intCast(new_row_index);
    }

    pub fn undoNew(self: *ArchetypeStorage) void {
        _ = self.entity_ids.pop();
    }

    pub fn remove(storage: *ArchetypeStorage, row_index: u32) !void {
        _ = storage.entity_ids.swapRemove(row_index);
        for (storage.components.values()) |component_storage| {
            component_storage.remove(component_storage.ptr, row_index);
        }
    }

    pub fn set(storage: *ArchetypeStorage, row_index: u32, name: []const u8, component: anytype) !void {
        const component_storage_erased = storage.components.get(name).?;
        var component_storage = ErasedComponentStorage.cast(component_storage_erased.ptr, @TypeOf(component));
        try component_storage.set(storage.allocator, row_index, component);
    }

    pub fn calculateHash(storage: *ArchetypeStorage) void {
        storage.hash = 0;
        var iter = storage.components.iterator();
        while (iter.next()) |entry| {
            const component_name = entry.key_ptr.*;
            storage.hash ^= std.hash_map.hashString(component_name);
        }
    }
};

pub const Registry = struct {
    const Self = @This();

    pub const Pointer = struct {
        archetype_index: u16,
        row_index: u32,
    };

    allocator: std.mem.Allocator,

    counter: Entity = 0,
    entities: std.AutoHashMapUnmanaged(Entity, Pointer) = .{},

    archetypes: std.AutoArrayHashMapUnmanaged(u64, ArchetypeStorage) = .{},

    pub fn init(allocator: std.mem.Allocator) !Self {
        var registry = Registry{
            .allocator = allocator,
        };

        try registry.archetypes.put(allocator, void_archetype_hash, ArchetypeStorage{
            .allocator = allocator,
            .components = .{},
            .hash = void_archetype_hash,
        });

        return registry;
    }

    pub fn deinit(self: *Self) void {
        var iter = self.archetypes.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }

        self.entities.deinit(self.allocator);
        self.archetypes.deinit(self.allocator);
    }

    pub fn new(self: *Self) !Entity {
        const new_id = self.counter;
        self.counter += 1;

        var void_archetype = self.archetypes.getPtr(void_archetype_hash).?;
        const new_row = try void_archetype.new(new_id);

        const void_pointer = Pointer{
            .archetype_index = 0, // void archetype is guaranteed to be first index
            .row_index = new_row,
        };

        self.entities.put(self.allocator, new_id, void_pointer) catch |err| {
            void_archetype.undoNew();
            return err;
        };

        return new_id;
    }

    pub inline fn archetypeByID(self: *Self, entity: Entity) *ArchetypeStorage {
        const ptr = self.entities.get(entity).?;
        return &self.archetypes.values()[ptr.archetype_index];
    }

    pub fn remove(self: *Self, entity: Entity) !void {
        var archetype = self.archetypeByID(entity);
        const ptr = self.entities.get(entity).?;

        const last_row_entity_id = archetype.entity_ids.items[archetype.entity_ids.items.len - 1];
        try self.entities.put(self.allocator, last_row_entity_id, Pointer{
            .archetype_index = ptr.archetype_index,
            .row_index = ptr.row_index,
        });

        try archetype.remove(ptr.row_index);

        _ = self.entities.remove(entity);
    }

    pub fn setComponent(self: *Self, entity: Entity, name: []const u8, component: anytype) !void {
        var archetype = self.archetypeByID(entity);

        const old_hash = archetype.hash;

        const have_already = archetype.components.contains(name);
        const new_hash = if (have_already) old_hash else old_hash ^ std.hash_map.hashString(name);

        const archetype_entry = try self.archetypes.getOrPut(self.allocator, new_hash);
        if (!archetype_entry.found_existing) {
            archetype_entry.value_ptr.* = ArchetypeStorage{
                .allocator = self.allocator,
                .components = .{},
                .hash = 0,
            };
            var new_archetype = archetype_entry.value_ptr;
            var column_iter = archetype.components.iterator();
            while (column_iter.next()) |entry| {
                var erased: ErasedComponentStorage = undefined;
                entry.value_ptr.cloneType(entry.value_ptr.*, &new_archetype.entity_ids.items.len, self.allocator, &erased) catch |err| {
                    std.debug.assert(self.archetypes.swapRemove(new_hash));
                    return err;
                };
                new_archetype.components.put(self.allocator, entry.key_ptr.*, erased) catch |err| {
                    std.debug.assert(self.archetypes.swapRemove(new_hash));
                    return err;
                };
            }

            const erased = self.initErasedStorage(&new_archetype.entity_ids.items.len, @TypeOf(component)) catch |err| {
                std.debug.assert(self.archetypes.swapRemove(new_hash));
                return err;
            };
            new_archetype.components.put(self.allocator, name, erased) catch |err| {
                std.debug.assert(self.archetypes.swapRemove(new_hash));
                return err;
            };

            new_archetype.calculateHash();
        }

        var current_archetype_storage = archetype_entry.value_ptr;

        if (new_hash == old_hash) {
            const ptr = self.entities.get(entity).?;
            try current_archetype_storage.set(ptr.row_index, name, component);
            return;
        }

        const new_row = try current_archetype_storage.new(entity);
        const old_ptr = self.entities.get(entity).?;

        var column_iter = archetype.components.iterator();
        while (column_iter.next()) |entry| {
            const old_component_storage = entry.value_ptr;
            var new_component_storage = current_archetype_storage.components.get(entry.key_ptr.*).?;
            new_component_storage.copy(new_component_storage.ptr, self.allocator, new_row, old_ptr.row_index, old_component_storage.ptr) catch |err| {
                current_archetype_storage.undoNew();
                return err;
            };
        }

        current_archetype_storage.entity_ids.items[new_row] = entity;

        current_archetype_storage.set(new_row, name, component) catch |err| {
            current_archetype_storage.undoNew();
            return err;
        };

        const swapped_entity_id = archetype.entity_ids.items[archetype.entity_ids.items.len - 1];
        archetype.remove(old_ptr.row_index) catch |err| {
            current_archetype_storage.undoNew();
            return err;
        };

        try self.entities.put(self.allocator, swapped_entity_id, old_ptr);

        try self.entities.put(self.allocator, entity, Pointer{
            .archetype_index = @intCast(archetype_entry.index),
            .row_index = new_row,
        });
    }

    pub fn getComponent(self: *Self, entity: Entity, name: []const u8, comptime Component: type) ?Component {
        var archetype = self.archetypeByID(entity);

        const component_storage_erased = archetype.components.get(name) orelse return null;

        const ptr = self.entities.get(entity).?;
        var component_storage = ErasedComponentStorage.cast(component_storage_erased.ptr, Component);
        return component_storage.get(ptr.row_index);
    }

    pub fn hasComponent(self: *Self, entity: Entity, name: []const u8, comptime Component: type) bool {
        return self.getComponent(entity, name, Component) != null;
    }

    pub fn removeComponent(self: *Self, entity: Entity, name: []const u8) !void {
        var archetype = self.archetypeByID(entity);
        if (!archetype.components.contains(name)) return;

        const old_hash = archetype.hash;

        var new_hash: u64 = 0;
        var iter = archetype.components.iterator();
        while (iter.next()) |entry| {
            const component_name = entry.key_ptr.*;
            if (!std.mem.eql(u8, component_name, name)) new_hash ^= std.hash_map.hashString(component_name);
        }
        std.debug.assert(new_hash != old_hash);

        const archetype_entry = try self.archetypes.getOrPut(self.allocator, new_hash);
        if (!archetype_entry.found_existing) {
            archetype_entry.value_ptr.* = ArchetypeStorage{
                .allocator = self.allocator,
                .components = .{},
                .hash = 0,
            };
            var new_archetype = archetype_entry.value_ptr;

            var column_iter = archetype.components.iterator();
            while (column_iter.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, name)) continue;
                var erased: ErasedComponentStorage = undefined;
                entry.value_ptr.cloneType(entry.value_ptr.*, &new_archetype.entity_ids.items.len, self.allocator, &erased) catch |err| {
                    std.debug.assert(self.archetypes.swapRemove(new_hash));
                    return err;
                };
                new_archetype.components.put(self.allocator, entry.key_ptr.*, erased) catch |err| {
                    std.debug.assert(self.archetypes.swapRemove(new_hash));
                    return err;
                };
            }
            new_archetype.calculateHash();
        }

        var current_archetype_storage = archetype_entry.value_ptr;

        const new_row = try current_archetype_storage.new(entity);
        const old_ptr = self.entities.get(entity).?;

        var column_iter = current_archetype_storage.components.iterator();
        while (column_iter.next()) |entry| {
            const src_component_storage = archetype.components.get(entry.key_ptr.*).?;
            var dst_component_storage = entry.value_ptr;
            dst_component_storage.copy(dst_component_storage.ptr, self.allocator, new_row, old_ptr.row_index, src_component_storage.ptr) catch |err| {
                current_archetype_storage.undoNew();
                return err;
            };
        }
        current_archetype_storage.entity_ids.items[new_row] = entity;

        const swapped_entity_id = archetype.entity_ids.items[archetype.entity_ids.items.len - 1];
        archetype.remove(old_ptr.row_index) catch |err| {
            current_archetype_storage.undoNew();
            return err;
        };
        try self.entities.put(self.allocator, swapped_entity_id, old_ptr);

        try self.entities.put(self.allocator, entity, Pointer{
            .archetype_index = @intCast(archetype_entry.index),
            .row_index = new_row,
        });
    }

    pub fn initErasedStorage(self: *const Self, total_rows: *usize, comptime Component: type) !ErasedComponentStorage {
        const new_ptr = try self.allocator.create(ComponentStorage(Component));
        new_ptr.* = ComponentStorage(Component){ .total_rows = total_rows };

        return ErasedComponentStorage{
            .ptr = new_ptr,
            .deinit = (struct {
                pub fn deinit(erased: *anyopaque, allocator: std.mem.Allocator) void {
                    var ptr = ErasedComponentStorage.cast(erased, Component);
                    ptr.deinit(allocator);
                    allocator.destroy(ptr);
                }
            }).deinit,
            .cloneType = (struct {
                pub fn cloneType(erased: ErasedComponentStorage, _total_rows: *usize, allocator: std.mem.Allocator, retval: *ErasedComponentStorage) !void {
                    const new_clone = try allocator.create(ComponentStorage(Component));
                    new_clone.* = ComponentStorage(Component){ .total_rows = _total_rows };
                    var tmp = erased;
                    tmp.ptr = new_clone;
                    retval.* = tmp;
                }
            }).cloneType,
            .copy = (struct {
                pub fn copy(dst_erased: *anyopaque, allocator: std.mem.Allocator, src_row: u32, dst_row: u32, src_erased: *anyopaque) !void {
                    var dst = ErasedComponentStorage.cast(dst_erased, Component);
                    const src = ErasedComponentStorage.cast(src_erased, Component);
                    return dst.copy(allocator, src_row, dst_row, src);
                }
            }).copy,
            .remove = (struct {
                pub fn remove(erased: *anyopaque, row: u32) void {
                    var ptr = ErasedComponentStorage.cast(erased, Component);
                    ptr.remove(row);
                }
            }).remove,
        };
    }
};
