const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn HashMap(K: type, V: type, comptime hash_fn: anytype, comptime eql_fn: anytype) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            key: K,
            value: V,
        };

        items: []Entry,
        capacity: u32,
        index_length: u5,
        _index: ?[*]u32,

        pub const empty: Self = .{
            .items = &.{},
            .capacity = 0,
            .index_length = 0,
            ._index = null,
        };

        fn index(self: *const Self) ?Index {
            if (self._index) |ptr| {
                const length = @as(u32, 1) << self.index_length;
                return .{ .array = ptr[0..length], .mask = length - 1 };
            } else {
                return null;
            }
        }

        fn len(self: *const Self) u32 {
            // Look, if your hash map gets this big, you have bigger problems
            return @intCast(self.items.len);
        }

        fn memory(self: *const Self) []Entry {
            const begin: [*]Entry = @ptrCast(&self.items[0]);
            return begin[0..self.capacity];
        }

        pub fn lookup(self: *const Self, key: K) ?*Entry {
            if (self.index()) |hash_index| {
                const hash = hash_fn(key);
                var iter = IndexIter{ .index = hash_index, .start = @truncate(hash) };
                while (iter.next()) |i| {
                    if (eql_fn(self.items[i].key, key))
                        return &self.items[i];
                }
            } else {
                for (self.items) |*item| {
                    if (eql_fn(item.key, key))
                        return item;
                }
            }
            return null;
        }

        fn load_factor(self: Self) u32 {
            if (self._index) |_| {
                return (self.len() * 100) >> self.index_length;
            } else {
                return 0;
            }
        }

        pub fn delete_index(self: *Self, allocator: Allocator) void {
            if (self.index()) |hash_index| {
                allocator.free(hash_index.array);
                self._index = null;
            }
        }

        pub fn reindex(self: *Self, allocator: Allocator) error{OutOfMemory}!void {
            const items_length_bits: u5 = @intCast(32 - @clz(@as(u32, @intCast(self.len()))));
            const new_index_length_bits: u5 = items_length_bits + 1;
            const new_items_length = @as(u32, 1) << new_index_length_bits;

            var hash_index: Index = .{
                .array = try allocator.alloc(u32, new_items_length),
                .mask = new_items_length - 1,
            };

            hash_index.clear();

            for (self.items, 0..) |entry, pos| {
                const hash = hash_fn(entry.key);
                const slot = hash_index.find_empty_slot(@truncate(hash)) orelse unreachable;
                hash_index.array[slot] = @intCast(pos);
            }

            self.delete_index(allocator);

            self._index = @ptrCast(&hash_index.array[0]);
            self.index_length = new_index_length_bits;
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.delete_index(allocator);
            allocator.free(self.memory());
        }

        pub fn reserve(self: *Self, allocator: Allocator, size: u32) error{OutOfMemory}!void {
            if (size > self.capacity) {
                if (self.capacity > 0) {
                    if (allocator.resize(self.memory(), size)) {
                        self.capacity = size;
                        return;
                    }
                }

                const new_slice = try allocator.alloc(Entry, size);
                if (self.capacity > 0) {
                    @memcpy(new_slice[0..self.items.len], self.items);
                    allocator.free(self.memory());
                }

                const ptr: [*]Entry = @ptrCast(&new_slice[0]);
                self.items = ptr[0..self.items.len];
                self.capacity = @intCast(new_slice.len);
            }
        }

        pub fn append(self: *Self, allocator: Allocator, key: K, value: V) error{OutOfMemory}!void {
            if (self.items.len == self.capacity) {
                const new_cap = if (self.len() == 0) 4 else 2 * self.len();
                try self.reserve(allocator, @intCast(new_cap));
            }

            self.items.len += 1;
            self.items[self.items.len - 1] = .{ .key = key, .value = value };

            if (self.index()) |hash_index| {
                const slot = hash_index.find_empty_slot(@truncate(hash_fn(key))) orelse unreachable;
                hash_index.array[slot] = self.len() - 1;

                if (self.load_factor() > 75)
                    try self.reindex(allocator);
            }
        }
    };
}

const Index = struct {
    array: []u32,
    mask: u32,

    fn slot(self: Index, start: u32, n: u32) u32 {
        return self.mask & (start +% ((n * (n + 1)) / 2));
        //return self.mask & (start +% n);
    }

    fn clear(self: Index) void {
        @memset(self.array, std.math.maxInt(u32));
    }

    fn find_empty_slot(self: Index, start: u32) ?u32 {
        for (0..self.array.len) |n| {
            const slt = self.slot(start, @intCast(n));
            if (self.array[slt] == std.math.maxInt(u32))
                return slt;
        }
        return null;
    }
};

const IndexIter = struct {
    index: Index,
    start: u32,
    n: u32 = 0,

    fn next(self: *IndexIter) ?u32 {
        if (self.n < self.index.array.len) {
            const value = self.index.array[self.index.slot(self.start, self.n)];
            self.n += 1;
            if (value != std.math.maxInt(u32))
                return value;
        }
        return null;
    }
};

fn test_hash(k: usize) u32 {
    return std.hash.Fnv1a_32.hash(std.mem.asBytes(&k));
}

fn test_eql(l: usize, r: usize) bool {
    return l == r;
}

const expect_equal = std.testing.expectEqual;

test "without index" {
    var map: HashMap(usize, usize, test_hash, test_eql) = .empty;
    const alloc = std.testing.allocator;
    defer map.deinit(alloc);

    for (1..100) |i| {
        try map.append(alloc, (20 * i) % 109, i);
    }
    for (1..100) |i| {
        try expect_equal(map.lookup((20 * i) % 109).?.value, i);
    }
}

test "with index" {
    var map: HashMap(usize, usize, test_hash, test_eql) = .empty;
    const alloc = std.testing.allocator;
    defer map.deinit(alloc);

    for (1..100) |i| {
        if (i == 10)
            try map.reindex(alloc);
        try map.append(alloc, (20 * i) % 109, i);
    }
    for (1..100) |i| {
        try expect_equal(map.lookup((20 * i) % 109).?.value, i);
    }
}
