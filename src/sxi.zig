const std = @import("std");
const assert = std.debug.assert;

pub const read = @import("read.zig").read;
pub const print = @import("print.zig").print;
pub const gc = @import("gc.zig");
pub const evaluate = @import("eval.zig").evaluate;
pub const compile = @import("compile.zig").compile;

pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &@import("allocator.zig").vtable,
};

pub const size_type = u32;

pub const Tag = enum(u8) {
    // Basic data types
    constant = 0,
    integer,
    symbol,

    // Compound data types
    pair,
    environment,
    vector,

    // Callables
    function,
    //kfunction,
    lambda,
    continuation,

    // Internals
    formals,
    code,
};

pub const Constant = enum(usize) {
    undefined = 0,
    false,
    true,
    eof,
    void,
    null, // i.e. Empty list
};

pub const c_null = SXI{ .constant = .null };
pub const c_void = SXI{ .constant = .void };
pub const c_false = SXI{ .constant = .false };
pub const c_true = SXI{ .constant = .true };
pub const c_eof = SXI{ .constant = .eof };

pub const Continuation = @import("eval.zig").Continuation;

pub const SXI = union(Tag) {
    constant: Constant,
    integer: isize,
    symbol: *Symbol,
    pair: *Pair,
    environment: *Environment,
    vector: *Vector,
    function: @import("eval.zig").Function,
    //kfunction,
    lambda: *Lambda,
    continuation: *Continuation,

    formals: *Formals,
    code: *Code,

    pub fn eq(self: SXI, other: SXI) bool {
        return std.meta.eql(self, other);
    }
};

comptime {
    assert(@sizeOf(SXI) == 2 * @sizeOf(usize));
}

pub const Pair = struct {
    first: SXI,
    second: SXI,
    pub fn split(p: Pair) struct { SXI, SXI } {
        return .{ p.first, p.second };
    }
};

pub fn pair(first: SXI, second: SXI) Pair {
    return .{ .first = first, .second = second };
}

pub const Symbol = extern struct {
    len: size_type,
    _data: [1]u8,

    pub fn data(s: *const Symbol) []const u8 {
        return @as([*]const u8, @ptrCast(&s._data[0]))[0..s.len];
    }
};

pub const Vector = struct {
    data: std.ArrayListUnmanaged(SXI),
};

pub const Formals = struct {
    names: []*Symbol,
    variadic: bool,
};

pub const Environment = struct {
    parent: ?*Environment,
    entries: std.ArrayListUnmanaged(Entry),

    pub const Entry = struct {
        name: *Symbol,
        value: SXI,
    };

    const SetError = error{
        NotDefined,
    };

    pub fn define(e: *Environment, name: *Symbol, value: SXI) void {
        for (e.entries.items) |*entry| {
            if (entry.name == name) {
                entry.value = value;
                return;
            }
        }
        e.entries.append(allocator, .{ .name = name, .value = value }) catch unreachable;
    }

    pub fn set(e: *Environment, name: *Symbol, value: SXI) SetError!void {
        for (e.entries.items) |entry| {
            if (entry.name == name) {
                entry.value = value;
                return;
            }
        }
        if (e.parent) |parent| {
            return parent.set(name, value);
        } else {
            return .NotDefined;
        }
    }

    pub fn lookup(e: *Environment, name: *Symbol) ?SXI {
        var ep = e;
        while (true) {
            for (ep.entries.items) |entry| {
                if (entry.name == name) {
                    return entry.value;
                }
            }
            if (ep.parent) |parent| {
                ep = parent;
            } else {
                return null;
            }
        }
    }
};

pub const OpcodeInt = u32;
pub const Opcode = @import("compile.zig").Opcode;

pub const Code = struct {
    instructions: []OpcodeInt,
    symbols: []*Symbol,
    literals: []SXI,
};

pub const Lambda = struct {
    capture: *Environment,
    arguments: *Formals,
    code: *Code,
};

pub fn wrap(x: anytype) SXI {
    const fieldname = comptime blk: {
        for (std.meta.fields(SXI)) |field| {
            if (std.meta.eql(@TypeOf(x), field.type)) {
                break :blk field.name;
            }
        }
        @compileError("SXI cannot wrap type: " ++ @typeName(@TypeOf(x)));
    };
    return @unionInit(SXI, fieldname, x);
}
