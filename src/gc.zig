const std = @import("std");
const assert = std.debug.assert;
const PageAllocator = std.heap.PageAllocator;

const sxi = @import("sxi.zig");
const SXI = sxi.SXI;
const allocator = sxi.allocator;

var symbol_pool = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var interned_symbols: std.ArrayListUnmanaged(*sxi.Symbol) = .empty;

pub fn make_symbol(name: []const u8) *sxi.Symbol {
    // Look for existing symbol in pool
    // TODO: make this a hashmap or something
    for (interned_symbols.items) |sym| {
        if (std.mem.eql(u8, name, sym.data())) {
            return sym;
        }
    }

    // Create new symbol
    const size = name.len + @sizeOf(sxi.Symbol);
    const ptr = symbol_pool.allocator().alignedAlloc(u8, @alignOf(sxi.Symbol), size) catch @panic("allocation failure");
    var sym: *sxi.Symbol = @ptrCast(ptr);

    sym.len = @intCast(name.len);
    sym.hash = @truncate(std.hash.Fnv1a_64.hash(name));

    const data: []u8 = @constCast(sym.data());
    @memcpy(data, name);

    // Add to interned pool
    interned_symbols.append(allocator, sym) catch @panic("allocation failure");
    return sym;
}

fn ObjectPool(comptime T: type) type {
    const item_size = @sizeOf(T);
    const slab_size = std.heap.page_size_min;
    const block_length = (slab_size / (1 + item_size)) & ~@as(usize, 0xf);

    const state = enum(u8) {
        inactive = 0,
        active,
        swept,
    };

    const Block = struct {
        states: [block_length]state,
        entries: [block_length]T,

        pub fn alloc(b: *@This(), x: *T) *T {
            const offset = x - &b.entries;
            assert(0 <= offset and offset < block_length);
            assert(b.states[offset] == .inactive);
            b.states[offset] = .active;
            //@memset(std.mem.asBytes(x), 0);
            allocation_counter += 1;
            return x;
        }

        pub fn sweep(b: *@This(), x: *T) void {
            const offset = x - &b.entries;
            assert(0 <= offset and offset < block_length);
            switch (b.states[offset]) {
                .swept => {},
                .active => {
                    b.states[offset] = .swept;
                    sweepChildren(x);
                },
                else => assert(false),
            }
        }

        pub fn cleanup(b: *@This(), frees: *?*T) void {
            for (0..block_length) |i| {
                const x: *T = &b.entries[i];
                switch (b.states[i]) {
                    .swept => {
                        b.states[i] = .active;
                    },
                    .active => {
                        b.states[i] = .inactive;
                        deallocate(x);
                        @as(*?*T, @ptrCast(x)).* = frees.*;
                        frees.* = x;
                    },
                    .inactive => {},
                }
            }
        }
    };
    assert(@sizeOf(Block) <= slab_size);

    return struct {
        const Self = @This();

        blocks: std.ArrayListUnmanaged(*Block),
        frees: ?*T,
        next_index: usize,

        pub const empty: Self = .{
            .blocks = std.ArrayListUnmanaged(*Block).empty,
            .frees = null,
            .next_index = block_length,
        };

        pub fn alloc(p: *Self) *T {
            // Allocate from free list
            if (p.frees) |x| {
                @branchHint(.likely);
                p.frees = @as(*?*T, @ptrCast(x)).*;
                const b: *Block = @ptrFromInt(@intFromPtr(x) & ~(slab_size - 1));
                return b.alloc(x);
            }

            // Allocate from end of slab
            if (p.next_index < block_length) {
                @branchHint(.likely);
                const b: *Block = p.blocks.getLast();
                const idx = p.next_index;
                p.next_index += 1;
                return b.alloc(&b.entries[idx]);
            }

            // Allocate new slab
            const slab = PageAllocator.map(slab_size, .fromByteUnits(slab_size)) orelse @panic("allocation error");
            const b: *Block = @ptrCast(@alignCast(slab));
            p.blocks.append(sxi.allocator, b) catch @panic("allocation error");
            p.next_index = 1;
            return b.alloc(&b.entries[0]);
        }

        pub fn sweep(_: *Self, x: *T) void {
            const b: *Block = @ptrFromInt(@intFromPtr(x) & ~(slab_size - 1));
            b.sweep(x);
        }

        pub fn cleanup(p: *Self) void {
            for (p.blocks.items) |*b| {
                b.*.cleanup(&p.frees);
            }
        }
    };
}

fn sweep(s: SXI) void {
    switch (s) {
        inline else => |val, tag| {
            const name = comptime @tagName(tag);
            if (@hasField(Pools, name)) {
                @field(pools, name).sweep(val);
            }
        },
    }
}

fn cleanup() void {
    inline for (std.meta.fields(Pools)) |field| {
        @field(pools, field.name).cleanup();
    }
    allocation_counter = 0;
}

const Pools = struct {
    pair: ObjectPool(sxi.Pair) = .empty,
    lambda: ObjectPool(sxi.Lambda) = .empty,
    vector: ObjectPool(sxi.Vector) = .empty,
    environment: ObjectPool(sxi.Environment) = .empty,
    code: ObjectPool(sxi.Code) = .empty,
    formals: ObjectPool(sxi.Formals) = .empty,
    continuation: ObjectPool(sxi.Continuation) = .empty,
    struct_type: ObjectPool(sxi.StructType) = .empty,
    struct_instance: ObjectPool(sxi.StructInstance) = .empty,
    thunk: ObjectPool(sxi.Thunk) = .empty,
};
var pools: Pools = .{};

pub var allocation_counter: usize = 0;

fn sweepChildren(x: anytype) void {
    switch (@TypeOf(x.*)) {
        sxi.Pair => {
            sweep(x.first);
            sweep(x.second);
        },
        sxi.Vector => {
            for (x.data.items) |y| {
                sweep(y);
            }
        },
        sxi.Environment => {
            for (x.map.items) |entry| {
                sweep(entry.value);
            }
        },
        sxi.Code => {
            for (x.literals) |literal| {
                sweep(literal);
            }
        },
        sxi.Lambda => {
            sweep(sxi.wrap(x.capture));
            sweep(sxi.wrap(x.arguments));
            sweep(sxi.wrap(x.code));
        },
        sxi.Continuation => {
            sweep(sxi.wrap(x.code));
            sweep(sxi.wrap(x.stack));
            sweep(sxi.wrap(x.environment));
            sweep(sxi.wrap(x.next));
        },
        sxi.StructInstance => {
            sweep(sxi.wrap(x.typ));
            for (x.fields) |f| {
                sweep(f);
            }
        },
        sxi.Thunk => {
            sweep(sxi.wrap(x.code));
            sweep(sxi.wrap(x.env));
        },
        else => {},
    }
}

fn deallocate(x: anytype) void {
    switch (@TypeOf(x.*)) {
        sxi.Vector => {
            x.data.deinit(sxi.allocator);
        },
        sxi.Environment => {
            x.map.deinit(sxi.allocator);
        },
        sxi.Formals => {
            sxi.allocator.free(x.names);
        },
        sxi.Code => {
            sxi.allocator.free(x.instructions);
            sxi.allocator.free(x.symbols);
            sxi.allocator.free(x.literals);
        },
        sxi.StructType => {
            sxi.allocator.free(x.fieldnames);
        },
        sxi.StructInstance => {
            sxi.allocator.free(x.fields);
        },
        else => {},
    }
}

var roots: std.ArrayListUnmanaged(SXI) = .empty;

pub fn protect(root: SXI) void {
    roots.append(allocator, root) catch @panic("allocation error");
}

pub fn run(extra_roots: []const SXI) void {
    for (roots.items) |v| {
        sweep(v);
    }
    for (extra_roots) |v| {
        sweep(v);
    }
    cleanup();
}

// Public allocation functions

pub fn make_pair(first: SXI, second: SXI) *sxi.Pair {
    const p = pools.pair.alloc();
    p.* = .{ .first = first, .second = second };
    return p;
}

pub fn make_vector() *sxi.Vector {
    const v = pools.vector.alloc();
    v.data = .empty;
    return v;
}

pub fn make_environment(parent: ?*sxi.Environment) *sxi.Environment {
    const e = pools.environment.alloc();
    e.* = .{ .map = .empty, .parent = parent };
    return e;
}

pub fn alloc(comptime tag: sxi.Tag) @FieldType(SXI, @tagName(tag)) {
    return @field(pools, @tagName(tag)).alloc();
}
