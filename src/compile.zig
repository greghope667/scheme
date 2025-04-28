const sxi = @import("sxi.zig");
const SXI = sxi.SXI;
const OI = sxi.OpcodeInt;
const allocator = sxi.allocator;
const gc = @import("gc.zig");

const std = @import("std");
const assert = std.debug.assert;
const Array = std.ArrayListUnmanaged;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub const Opcode = enum(OI) {
    allocate_stack,
    lookup_callable,
    lookup_variable,
    call,
    tailcall,
    literal,
    ret,
    branch,
    branch0,
    push,
    define,
    exit,
    lambda,
    push_callable,
    allocate_cont,
};

const CompileError = error{
    SyntaxError,
    NotAList,
    OutOfMemory,
    TooManyLiterals,
    TooManySymbols,
    CodeSizeLimit,
    ValueNotCallable,
};

const CodeBuilder = struct {
    code: Array(OI),
    symbols: Array(*sxi.Symbol),
    literals: Array(SXI),

    const max_length = std.math.maxInt(OI) / 2;

    const empty: CodeBuilder = .{
        .code = .empty,
        .symbols = .empty,
        .literals = .empty,
    };

    fn deinit(self: *CodeBuilder) void {
        self.code.deinit(allocator);
        self.literals.deinit(allocator);
        self.symbols.deinit(allocator);
    }

    fn to_owned(self: *CodeBuilder) CompileError!*sxi.Code {
        const code = gc.alloc(.code);
        code.* = .{
            .instructions = try self.code.toOwnedSlice(allocator),
            .literals = try self.literals.toOwnedSlice(allocator),
            .symbols = try self.symbols.toOwnedSlice(allocator),
        };
        return code;
    }

    fn append_opc(self: *CodeBuilder, op: Opcode) CompileError!void {
        try self.code.append(allocator, @intFromEnum(op));
    }

    fn append_sym(self: *CodeBuilder, symbol: *sxi.Symbol) CompileError!void {
        try self.code.append(allocator, try self.next_symbol());
        try self.symbols.append(allocator, symbol);
    }

    fn append_lit(self: *CodeBuilder, lit: SXI) CompileError!void {
        try self.code.append(allocator, try self.next_literal());
        try self.literals.append(allocator, lit);
    }

    fn append_int(self: *CodeBuilder, int: usize) CompileError!void {
        try self.code.append(allocator, @intCast(int));
    }

    fn append(self: *CodeBuilder, args: anytype) CompileError!void {
        inline for (args) |a| {
            try switch (@TypeOf(a)) {
                Opcode => self.append_opc(a),
                SXI => self.append_lit(a),
                *sxi.Symbol => self.append_sym(a),
                usize => self.append_int(a),
                comptime_int => self.code.append(allocator, @intCast(a)),
                else => @compileError("Unsupported type"),
            };
        }
        if (self.code.items.len > max_length) {
            return CompileError.CodeSizeLimit;
        }
    }

    fn next_symbol(self: CodeBuilder) CompileError!OI {
        const idx = self.symbols.items.len;
        return if (idx > max_length) CompileError.TooManySymbols else @intCast(idx);
    }

    fn next_literal(self: CodeBuilder) CompileError!OI {
        const idx = self.literals.items.len;
        return if (idx > max_length) CompileError.TooManyLiterals else @intCast(idx);
    }
};

fn list_length(list: *sxi.Pair) CompileError!usize {
    // TODO: handle improper circular lists
    var p = list;
    var length: usize = 0;
    while (true) {
        length += 1;
        const cdr = p.second;
        if (cdr.eq(sxi.c_null)) {
            return length;
        } else switch (p.second) {
            .pair => |p2| {
                p = p2;
            },
            else => {
                return CompileError.NotAList;
            },
        }
    }
}

test "flatten_list" {
    const l1 = gc.cons(sxi.c_true, sxi.c_null);
    const l2 = gc.cons(sxi.c_false, sxi.wrap(l1));
    //try std.testing.expect(try list_length(l1) == 1);
    try std.testing.expect((try flatten_list(l1)).len == 1);
    //try std.testing.expect(try list_length(l2) == 2);
    try std.testing.expect((try flatten_list(l2)).len == 2);
}

fn flatten_list(list: *sxi.Pair) CompileError![]SXI {
    const length = try list_length(list);
    const arr = try arena.allocator().alloc(SXI, length);

    var p = sxi.wrap(list);
    for (arr) |*entry| {
        entry.* = p.pair.first;
        p = p.pair.second;
    }
    return arr;
}

fn compile_expr(expr: SXI, code: *CodeBuilder, is_tail: bool) CompileError!void {
    return switch (expr) {
        .pair => |p| compile_list(try flatten_list(p), code, is_tail),
        .symbol => |s| compile_symbol(s, code, is_tail),
        else => compile_literal(expr, code, is_tail),
    };
}

fn compile_list(list: []SXI, code: *CodeBuilder, is_tail: bool) CompileError!void {
    switch (list[0]) {
        .symbol => |s| {
            for (special_forms) |form| {
                if (form.symbol == s) {
                    return form.func(list, code, is_tail);
                }
            }
        },
        else => {},
    }

    if (list.len > CodeBuilder.max_length) {
        return CompileError.CodeSizeLimit;
    }

    if (!is_tail) {
        try code.append_opc(Opcode.allocate_cont);
    }
    try code.append(.{ Opcode.allocate_stack, list.len });

    try switch (list[0]) {
        .pair => |p| {
            try compile_list(try flatten_list(p), code, false);
            try code.append_opc(Opcode.push_callable);
        },
        .symbol => |s| code.append(.{ Opcode.lookup_callable, s }),
        .function_1, .function_n, .lambda => code.append(.{ Opcode.literal, list[0], Opcode.push }),
        else => return CompileError.ValueNotCallable,
    };

    for (list[1..]) |expr| {
        try switch (expr) {
            .pair => |p| {
                try compile_list(try flatten_list(p), code, false);
                try code.append_opc(Opcode.push);
            },
            .symbol => |s| code.append(.{ Opcode.lookup_variable, s, Opcode.push }),
            else => code.append(.{ Opcode.literal, expr, Opcode.push }),
        };
    }

    try code.append_opc(if (is_tail) Opcode.tailcall else Opcode.call);
}

fn compile_literal(value: SXI, code: *CodeBuilder, is_tail: bool) CompileError!void {
    try code.append(.{ Opcode.literal, value });
    if (is_tail) {
        try code.append_opc(Opcode.ret);
    }
}

fn compile_symbol(sym: *sxi.Symbol, code: *CodeBuilder, is_tail: bool) CompileError!void {
    try code.append(.{ Opcode.lookup_variable, sym });
    if (is_tail) {
        try code.append_opc(Opcode.ret);
    }
}

pub fn compile(expr: SXI) CompileError!*sxi.Code {
    _ = arena.reset(.retain_capacity);
    var code: CodeBuilder = .empty;
    errdefer code.deinit();
    try compile_expr(expr, &code, true);
    return code.to_owned();
}

const SpecialForm = struct {
    name: []const u8,
    symbol: *sxi.Symbol,
    func: *const fn ([]SXI, *CodeBuilder, bool) CompileError!void,
};

fn compile_if(form: []SXI, code: *CodeBuilder, is_tail: bool) CompileError!void {
    const has_else_form = switch (form.len) {
        3 => false,
        4 => true,
        else => return CompileError.SyntaxError,
    };
    // Conditional
    try compile_expr(form[1], code, false);
    try code.append(.{ Opcode.branch0, std.math.maxInt(OI) });
    const branch0_from = code.code.items.len - 1;

    // True case
    try compile_expr(form[2], code, is_tail);
    if (!is_tail) {
        try code.append(.{ Opcode.branch, std.math.maxInt(OI) });
    }
    const branch_from = code.code.items.len - 1;

    // False case
    code.code.items[branch0_from] = @intCast(code.code.items.len - branch0_from + 1);
    if (has_else_form) {
        try compile_expr(form[3], code, is_tail);
    } else {
        try compile_literal(sxi.c_void, code, is_tail);
    }

    if (!is_tail) {
        code.code.items[branch_from] = @intCast(code.code.items.len - branch_from + 1);
    }
}

fn compile_define(form: []SXI, code: *CodeBuilder, is_tail: bool) CompileError!void {
    var name = sxi.c_void;

    if (form.len >= 2 and form[1] == .pair) {
        // (define (name . args) . body) -> (define name (lambda args . body))
        name = form[1].pair.first;
        form[1] = form[1].pair.second;
        try compile_lambda(form, code, false);
    } else if (form.len == 3) {
        // (define name expr)
        name = form[1];
        try compile_expr(form[2], code, false);
    }

    switch (name) {
        .symbol => |s| try code.append(.{ Opcode.define, s }),
        else => return CompileError.SyntaxError,
    }

    if (is_tail) {
        try code.append_opc(Opcode.ret);
    }
}

fn parse_formals(expr: SXI) CompileError!*sxi.Formals {
    var arg_array: Array(*sxi.Symbol) = .empty;
    errdefer arg_array.deinit(allocator);
    var is_variadic = false;

    loop: switch (expr) {
        .pair => |p| {
            switch (p.first) {
                .symbol => |s| {
                    try arg_array.append(allocator, s);
                    continue :loop p.second;
                },
                else => return CompileError.SyntaxError,
            }
        },
        .symbol => |s| {
            try arg_array.append(allocator, s);
            is_variadic = true;
        },
        .constant => |c| {
            if (c != .null) {
                return CompileError.SyntaxError;
            }
        },
        else => return CompileError.SyntaxError,
    }

    const formals = gc.alloc(.formals);
    formals.* = .{
        .names = try arg_array.toOwnedSlice(allocator),
        .variadic = is_variadic,
    };
    return formals;
}

fn compile_lambda(form: []SXI, code: *CodeBuilder, is_tail: bool) CompileError!void {
    if (form.len < 3) {
        return CompileError.SyntaxError;
    }

    // Extract argument form
    const formals = try parse_formals(form[1]);
    try code.append(.{ Opcode.lambda, sxi.wrap(formals) });

    // Compile body
    var lambda_code: CodeBuilder = .empty;
    errdefer lambda_code.deinit();
    try compile_begin(form[1..], &lambda_code, true);
    try code.literals.append(allocator, sxi.wrap(try lambda_code.to_owned()));

    if (is_tail) {
        try code.append_opc(Opcode.ret);
    }
}

fn compile_begin(form: []SXI, code: *CodeBuilder, is_tail: bool) CompileError!void {
    if (form.len == 1) {
        return compile_literal(sxi.c_void, code, is_tail);
    }
    for (form[1 .. form.len - 1]) |expr| {
        try compile_expr(expr, code, false);
    }
    try compile_expr(form[form.len - 1], code, is_tail);
}

fn compile_quote(form: []SXI, code: *CodeBuilder, is_tail: bool) CompileError!void {
    if (form.len != 2) {
        return CompileError.SyntaxError;
    }
    return compile_literal(form[1], code, is_tail);
}

var special_forms = [_]SpecialForm{
    .{ .name = "if", .symbol = undefined, .func = compile_if },
    .{ .name = "define", .symbol = undefined, .func = compile_define },
    .{ .name = "lambda", .symbol = undefined, .func = compile_lambda },
    .{ .name = "begin", .symbol = undefined, .func = compile_begin },
    .{ .name = "quote", .symbol = undefined, .func = compile_quote },
};

pub fn init_compile_symbols() void {
    for (&special_forms) |*form| {
        form.symbol = gc.make_symbol(form.name);
    }
}
