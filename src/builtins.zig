/// Builtins implemented in zig code
/// These are mostly taken from r7rs
const sxi = @import("sxi.zig");
const SXI = sxi.SXI;
const wrap = sxi.wrap;
const gc = @import("gc.zig");

const std = @import("std");

const Err = error{
    InvalidArguments,
    Overflow,
    DivideByZero,
};

// Function types.
pub const Function_n = *const fn ([]SXI) Err!SXI;
pub const Function_1 = *const fn (SXI) Err!SXI;

// Helpers for extracting arguments
const as = sxi.as;

fn as_int(value: SXI) Err!isize {
    return switch (value) {
        .integer => |i| i,
        else => Err.InvalidArguments,
    };
}

fn as_bool(value: SXI) Err!bool {
    if (value.eq(sxi.c_true)) {
        return true;
    } else if (value.eq(sxi.c_false)) {
        return false;
    } else {
        return Err.InvalidArguments;
    }
}

fn check_length(args: []const SXI, min: usize, max: usize) Err!void {
    return if (min <= args.len and args.len <= max) {} else Err.InvalidArguments;
}

// Equivalence procedures

/// scheme: eq? (r7rs)
fn eq_p(args: []const SXI) Err!SXI {
    if (args.len == 0) {
        return sxi.c_true;
    }
    const first = args[0];
    for (args[1..]) |a| {
        if (!first.eq(a)) {
            return sxi.c_false;
        }
    }
    return sxi.c_true;
}

/// scheme: eqv? (r7rs)
/// eqv? is close to eq? in definition, except eqv? must compare the value
/// of non-compound data types (numbers, characters). Currently we store these
/// types inside the SXI struct (not boxed), so a memory comparison (like eq?)
/// works here.
fn eqv_p(args: []const SXI) Err!SXI {
    return eq_p(args);
}

/// TODO: equal?

// Numbers (integers only currently)
const min_int = std.math.minInt(isize);
const max_int = std.math.maxInt(isize);

/// scheme: integer? (r7rs)
/// scheme: number? (r7rs)
fn integer_p(v: SXI) Err!SXI {
    return wrap(v == .integer);
}

/// scheme: = (r7rs)
fn equals(args: []SXI) Err!SXI {
    if (args.len == 0) {
        return wrap(true);
    }
    const first = try as_int(args[0]);
    for (args[1..]) |a| {
        if (try as_int(a) != first) {
            return wrap(false);
        }
    }
    return wrap(true);
}

/// scheme: < (r7rs)
fn less_than(args: []SXI) Err!SXI {
    if (args.len == 0) {
        return wrap(true);
    }
    var largest = try as_int(args[0]);
    for (args[1..]) |a| {
        const i = try as_int(a);
        if (largest < i) {
            largest = i;
        } else {
            return wrap(false);
        }
    }
    return wrap(true);
}

/// scheme: > (r7rs)
fn greater_than(args: []SXI) Err!SXI {
    if (args.len == 0) {
        return wrap(true);
    }
    var smallest = try as_int(args[0]);
    for (args[1..]) |a| {
        const i = try as_int(a);
        if (smallest > i) {
            smallest = i;
        } else {
            return wrap(false);
        }
    }
    return wrap(true);
}

/// scheme: <= (r7rs)
fn less_equal(args: []SXI) Err!SXI {
    if (args.len == 0) {
        return wrap(true);
    }
    var largest = try as_int(args[0]);
    for (args[1..]) |a| {
        const i = try as_int(a);
        if (largest <= i) {
            largest = i;
        } else {
            return wrap(false);
        }
    }
    return wrap(true);
}

/// scheme: >= (r7rs)
fn greater_equal(args: []SXI) Err!SXI {
    if (args.len == 0) {
        return wrap(true);
    }
    var smallest = try as_int(args[0]);
    for (args[1..]) |a| {
        const i = try as_int(a);
        if (smallest >= i) {
            smallest = i;
        } else {
            return wrap(false);
        }
    }
    return wrap(true);
}

/// scheme: zero? (r7rs)
fn zero_p(v: SXI) Err!SXI {
    return switch (v) {
        .integer => |i| wrap(i == 0),
        else => Err.InvalidArguments,
    };
}

/// scheme: positive? (r7rs)
fn positive_p(v: SXI) Err!SXI {
    return switch (v) {
        .integer => |i| wrap(i > 0),
        else => Err.InvalidArguments,
    };
}

/// scheme: negative? (r7rs)
fn negative_p(v: SXI) Err!SXI {
    return switch (v) {
        .integer => |i| wrap(i < 0),
        else => Err.InvalidArguments,
    };
}

/// scheme: odd? (r7rs)
fn odd_p(v: SXI) Err!SXI {
    return switch (v) {
        .integer => |i| wrap(i & 1 == 1),
        else => Err.InvalidArguments,
    };
}

/// scheme: even? (r7rs)
fn even_p(v: SXI) Err!SXI {
    return switch (v) {
        .integer => |i| wrap(i & 1 == 0),
        else => Err.InvalidArguments,
    };
}

/// scheme: + (r7rs)
fn plus(args: []SXI) Err!SXI {
    var total: isize = 0;
    for (args) |a| {
        total, const overflow = @addWithOverflow(total, try as_int(a));
        if (overflow != 0) {
            return Err.Overflow;
        }
    }
    return wrap(total);
}

/// scheme: * (r7rs)
fn times(args: []SXI) Err!SXI {
    var product: isize = 1;
    for (args) |a| {
        product, const overflow = @mulWithOverflow(product, try as_int(a));
        if (overflow != 0) {
            return Err.Overflow;
        }
    }
    return wrap(product);
}

/// scheme: - (r7rs)
fn sub(args: []SXI) Err!SXI {
    return switch (args.len) {
        0 => Err.InvalidArguments,
        1 => wrap(try sub2(0, args[0])),
        else => {
            var total: isize = try as_int(args[0]);
            for (args[1..]) |a| {
                total = try sub2(total, a);
            }
            return wrap(total);
        },
    };
}

fn sub2(x: isize, y: SXI) Err!isize {
    const z, const overflow = @subWithOverflow(x, try as_int(y));
    if (overflow != 0) {
        return Err.Overflow;
    }
    return z;
}

/// scheme: abs (r7rs)
fn abs(x: SXI) Err!SXI {
    const i = try as_int(x);
    return if (i == min_int) Err.Overflow else wrap(-i);
}

fn div_args(args: []SXI) Err!struct { isize, isize } {
    try check_length(args, 2, 2);
    const x = try as_int(args[0]);
    const y = try as_int(args[1]);
    if (y == 0) {
        return Err.DivideByZero;
    } else if (x == min_int and y == -1) {
        return Err.Overflow;
    }
    return .{ x, y };
}

/// scheme: floor-quotient (r7rs)
fn floor_quotient(args: []SXI) Err!SXI {
    const x, const y = try div_args(args);
    return wrap(@divFloor(x, y));
}

/// scheme: floor-remainder (r7rs)
/// scheme: modulo (r7rs)
fn floor_remainder(args: []SXI) Err!SXI {
    const x, const y = try div_args(args);
    return wrap(@mod(x, y));
}

/// scheme: truncate-quotient (r7rs)
/// scheme: quotient (r7rs)
fn truncate_quotient(args: []SXI) Err!SXI {
    const x, const y = try div_args(args);
    return wrap(@divTrunc(x, y));
}

/// scheme: truncate-remainder (r7rs)
/// scheme: remainder (r7rs)
fn truncate_remainder(args: []SXI) Err!SXI {
    const x, const y = try div_args(args);
    return wrap(@rem(x, y));
}

/// scheme: square (r7rs)
fn square(x: SXI) Err!SXI {
    const i = try as_int(x);
    const r, const overflow = @mulWithOverflow(i, i);
    if (overflow != 0) {
        return Err.Overflow;
    }
    return wrap(r);
}

// Booleans

/// scheme: boolean? (r7rs)
fn boolean_p(x: SXI) Err!SXI {
    return switch (x) {
        .constant => |c| wrap(c == .true or c == .false),
        else => wrap(false),
    };
}

/// scheme: boolean=? (r7rs)
fn boolean_equals(args: []SXI) Err!SXI {
    if (args.len == 0) {
        return wrap(true);
    }
    _ = as_bool(args[0]) catch return wrap(false);
    return eq_p(args);
}

/// scheme: not (r7rs)
fn not(x: SXI) Err!SXI {
    return wrap(sxi.c_false.eq(x));
}

// Pairs and Lists

/// scheme: pair? (r7rs)
fn pair_p(x: SXI) Err!SXI {
    return wrap(x == .pair);
}

/// scheme: cons (r7rs)
fn cons(args: []SXI) Err!SXI {
    try check_length(args, 2, 2);
    return wrap(gc.cons(args[0], args[1]));
}

/// scheme: car (r7rs)
/// scheme: first (srfi 1)
fn car(x: SXI) Err!SXI {
    return (try as(.pair, x)).first;
}

/// scheme: cdr (r7rs)
/// scheme: rest (common lisp?)
fn cdr(x: SXI) Err!SXI {
    return (try as(.pair, x)).second;
}

/// scheme: set-car! (r7rs)
fn set_car(args: []SXI) Err!SXI {
    try check_length(args, 2, 2);
    (try as(.pair, args[0])).first = args[1];
    return args[0];
}

/// scheme: set-cdr! (r7rs)
fn set_cdr(args: []SXI) Err!SXI {
    try check_length(args, 2, 2);
    (try as(.pair, args[0])).second = args[1];
    return args[0];
}

/// scheme: null? (r7rs)
fn null_p(x: SXI) Err!SXI {
    return wrap(sxi.c_null.eq(x));
}

const Listerator = struct {
    expr: SXI,

    fn next(self: *Listerator) error{InvalidArguments}!?SXI {
        return switch (self.expr) {
            .pair => |p| {
                self.expr = p.second;
                return p.first;
            },
            .constant => |c| if (c == .null) null else Err.InvalidArguments,
            else => Err.InvalidArguments,
        };
    }
};

fn listerate(x: SXI) Listerator {
    return .{ .expr = x };
}

const ListBuilderFwd = struct {
    head: SXI = sxi.c_null,
    tail: *SXI = undefined,

    fn init(self: *ListBuilderFwd) void {
        self.head = sxi.c_null;
        self.tail = &self.head;
    }

    fn push(self: *ListBuilderFwd, value: SXI) void {
        const pair = gc.make(.pair);
        pair.first = value;
        pair.second = sxi.c_null;
        self.tail.* = wrap(pair);
        self.tail = &pair.second;
    }
};

const ListBuilderRev = struct {
    head: SXI = sxi.c_null,

    fn push(self: *ListBuilderRev, value: SXI) void {
        self.head = wrap(gc.cons(value, self.head));
    }
};

/// scheme: list? (r7rs)
fn list_p(x: SXI) Err!SXI {
    var iter = listerate(x);
    while (iter.next()) |maybe_value| {
        _ = maybe_value orelse return wrap(true);
    } else |_| {
        return wrap(false);
    }
}

/// scheme: make-list (r7rs)
fn make_list(args: []SXI) Err!SXI {
    try check_length(args, 1, 2);
    const length = try as_int(args[0]);
    const fill = if (args.len == 1) sxi.c_void else args[1];
    var head = sxi.c_null;
    if (length < 0) {
        return Err.InvalidArguments;
    }
    for (0..@intCast(length)) |_| {
        head = wrap(gc.cons(fill, head));
    }
    return head;
}

/// scheme: list (r7rs)
fn list(args: []SXI) Err!SXI {
    var head = sxi.c_null;
    var i: usize = args.len;
    while (i > 0) {
        i -= 1;
        head = wrap(gc.cons(args[i], head));
    }
    return head;
}

/// scheme: length (r7rs)
/// scheme: list-length (no standard)
fn list_length(x: SXI) Err!SXI {
    var i: isize = 0;
    var iter = listerate(x);
    while (try iter.next()) |_| {
        i += 1;
    }
    return wrap(i);
}

/// scheme: append (r7rs)
/// scheme: list-append (no standard)
fn list_append(args: []SXI) Err!SXI {
    if (args.len == 0) {
        return sxi.c_null;
    }
    var out = ListBuilderFwd{};
    out.init();
    for (args[0 .. args.len - 1]) |a| {
        var iter = listerate(a);
        while (try iter.next()) |value| {
            out.push(value);
        }
    }
    out.tail.* = args[args.len - 1];
    return out.head;
}

/// scheme: reverse (r7rs)
/// scheme: list-reverse (no standard)
fn list_reverse(l: SXI) Err!SXI {
    var out = ListBuilderRev{};
    var iter = listerate(l);
    while (try iter.next()) |value| {
        out.push(value);
    }
    return out.head;
}

/// scheme: list-tail (r7rs)
fn list_tail(args: []SXI) Err!SXI {
    try check_length(args, 2, 2);
    var iter = listerate(args[0]);
    var length = try as_int(args[1]);
    while (length > 0) : (length -= 1) {
        _ = (try iter.next()) orelse return Err.InvalidArguments;
    }
    return iter.expr;
}

/// scheme: list-ref (r7rs)
fn list_ref(args: []SXI) Err!SXI {
    return car(try list_tail(args));
}

/// scheme: list-set! (r7rs)
fn list_set(args: []SXI) Err!SXI {
    try (check_length(args, 3, 3));
    (try as(.pair, try list_tail(args[0..2]))).first = args[2];
    return args[0];
}

/// scheme: list-copy (r7rs)
fn list_copy(l: SXI) Err!SXI {
    var out = ListBuilderFwd{};
    out.init();
    var iter = listerate(l);
    while (try iter.next()) |value| {
        out.push(value);
    }
    return out.head;
}

const exports_f_n = &[_]struct { []const u8, Function_n }{
    .{ "eq?", &eq_p },
    .{ "eqv?", &eqv_p },
    .{ "=", &equals },
    .{ "<", &less_than },
    .{ "<=", &less_equal },
    .{ ">", &greater_than },
    .{ ">=", &greater_equal },
    .{ "+", &plus },
    .{ "*", &times },
    .{ "-", &sub },
    .{ "floor-quotient", &floor_quotient },
    .{ "floor-remainder", &floor_remainder },
    .{ "modulo", &floor_remainder },
    .{ "truncate-quotient", &truncate_quotient },
    .{ "quotient", &truncate_quotient },
    .{ "truncate-remainder", &truncate_remainder },
    .{ "remainder", &truncate_remainder },
    .{ "boolean=?", &boolean_equals },
    .{ "cons", &cons },
    .{ "set-car!", &set_car },
    .{ "set-cdr!", &set_cdr },
    .{ "make-list", &make_list },
    .{ "list", &list },
    .{ "append", &list_append },
    .{ "list-append", &list_append },
    .{ "list-tail", &list_tail },
    .{ "list-ref", &list_ref },
    .{ "list-set!", &list_set },
};

const exports_f_1 = &[_]struct { []const u8, Function_1 }{
    .{ "integer?", &integer_p },
    .{ "number?", &integer_p },
    .{ "zero?", &zero_p },
    .{ "positive?", &positive_p },
    .{ "negative?", &negative_p },
    .{ "odd?", &odd_p },
    .{ "even?", &even_p },
    .{ "abs", &abs },
    .{ "square", &square },
    .{ "boolean?", &boolean_p },
    .{ "not", &not },
    .{ "pair?", &pair_p },
    .{ "car", &car },
    .{ "first", &car },
    .{ "cdr", &cdr },
    .{ "rest", &cdr },
    .{ "null?", &null_p },
    .{ "list?", &list_p },
    .{ "length", &list_length },
    .{ "list-length", &list_length },
    .{ "reverse", &list_reverse },
    .{ "list-reverse", &list_reverse },
    .{ "list-copy", &list_copy },
};

pub fn make_root_environment() *sxi.Environment {
    const env = gc.make_environment(null);
    for (exports_f_1) |e| {
        const name, const f = e;
        env.define(gc.make_symbol(name), wrap(f));
    }
    for (exports_f_n) |e| {
        const name, const f = e;
        env.define(gc.make_symbol(name), wrap(f));
    }
    return env;
}
