// General purpose single-threaded allocator
// Stripped down version of Zig's Smp Allocator

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const math = std.math;
const Allocator = std.mem.Allocator;
const PageAllocator = std.heap.PageAllocator;

const slab_len: usize = @max(std.heap.page_size_max, 16 * 1024);
const min_class = math.log2(@sizeOf(usize));
const size_class_count = math.log2(slab_len) - min_class;

var next_addrs: [size_class_count]usize = @splat(0);
var frees: [size_class_count]usize = @splat(0);

pub const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

fn alloc(context: *anyopaque, len: usize, alignment: mem.Alignment, ra: usize) ?[*]u8 {
    _ = context;
    _ = ra;
    const class = sizeClassIndex(len, alignment);
    if (class >= size_class_count) {
        @branchHint(.unlikely);
        return PageAllocator.map(len, alignment);
    }

    const slot_size = slotSize(class);
    assert(slab_len % slot_size == 0);

    // Allocate from free list
    const top_free_ptr = frees[class];
    if (top_free_ptr != 0) {
        @branchHint(.likely);
        const node: *usize = @ptrFromInt(top_free_ptr);
        frees[class] = node.*;
        return @ptrFromInt(top_free_ptr);
    }

    // Allocate unused space in current slab
    const next_addr = next_addrs[class];
    if ((next_addr % slab_len) != 0) {
        @branchHint(.likely);
        next_addrs[class] = next_addr + slot_size;
        return @ptrFromInt(next_addr);
    }

    // Get new slab from page allocator
    const slab = PageAllocator.map(slab_len, .fromByteUnits(slab_len)) orelse return null;
    next_addrs[class] = @intFromPtr(slab) + slot_size;
    return slab;
}

fn resize(context: *anyopaque, memory: []u8, alignment: mem.Alignment, new_len: usize, ra: usize) bool {
    _ = context;
    _ = ra;
    const class = sizeClassIndex(memory.len, alignment);
    const new_class = sizeClassIndex(new_len, alignment);
    if (class >= size_class_count) {
        if (new_class < size_class_count) return false;
        return PageAllocator.realloc(memory, new_len, false) != null;
    }
    return new_class == class;
}

fn remap(context: *anyopaque, memory: []u8, alignment: mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    _ = context;
    _ = ra;
    const class = sizeClassIndex(memory.len, alignment);
    const new_class = sizeClassIndex(new_len, alignment);
    if (class >= size_class_count) {
        if (new_class < size_class_count) return null;
        return PageAllocator.realloc(memory, new_len, true);
    }
    return if (new_class == class) memory.ptr else null;
}

fn free(context: *anyopaque, memory: []u8, alignment: mem.Alignment, ra: usize) void {
    _ = context;
    _ = ra;
    const class = sizeClassIndex(memory.len, alignment);
    if (class >= size_class_count) {
        @branchHint(.unlikely);
        return PageAllocator.unmap(@alignCast(memory));
    }

    const node: *usize = @alignCast(@ptrCast(memory.ptr));
    node.* = frees[class];
    frees[class] = @intFromPtr(node);
}

fn sizeClassIndex(len: usize, alignment: mem.Alignment) usize {
    return @max(@bitSizeOf(usize) - @clz(len - 1), @intFromEnum(alignment), min_class) - min_class;
}

fn slotSize(class: usize) usize {
    return @as(usize, 1) << @intCast(class + min_class);
}
