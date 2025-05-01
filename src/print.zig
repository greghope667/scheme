const sxi = @import("sxi.zig");
const SXI = sxi.SXI;
const gc = @import("gc.zig");

const std = @import("std");
const assert = std.debug.assert;
const Error = anyerror;

const stdout = @import("ports.zig").stdout;
const writer = stdout.writer();

fn print_constant(c: sxi.Constant) Error!void {
    try writer.writeAll(switch (c) {
        .eof => "EOF",
        .false => "#f",
        .null => "()",
        .true => "#t",
        .undefined => "#!undefined",
        .void => "#void",
    });
}

fn print_pair(p: *sxi.Pair) Error!void {
    var current = p;
    try writer.writeByte('(');
    loop: while (true) {
        try print_value(current.first);
        switch (current.second) {
            .pair => |next| {
                try writer.writeByte(' ');
                current = next;
            },
            else => break :loop,
        }
    }
    if (!current.second.eq(sxi.c_null)) {
        try writer.writeAll(" . ");
        try print_value(current.second);
    }
    try writer.writeByte(')');
}

fn print_vector(v: *sxi.Vector) Error!void {
    try writer.writeAll("#(");
    for (v.data.items) |e| {
        try print_value(e);
        try writer.writeByte(' ');
    }
    try writer.writeByte(')');
}

fn print_struct(s: *sxi.StructInstance) Error!void {
    try writer.print("#<struct {s}", .{s.typ.name.data()});
    for (s.typ.fieldnames, s.fields) |name, value| {
        try writer.print(" {s}:", .{name.data()});
        try print_value(value);
    }
    try writer.writeByte('>');
}

fn print_formals(f: *sxi.Formals) Error!void {
    try writer.writeAll("#<formals(");
    for (f.names[0 .. f.names.len - 1]) |name|
        try writer.print("{s} ", .{name.data()});
    if (f.variadic)
        try writer.writeAll(". ");
    try writer.print("{s})>", .{f.names[f.names.len - 1].data()});
}

fn print_value(value: SXI) Error!void {
    try switch (value) {
        .constant => |c| print_constant(c),
        .integer => |i| writer.print("{}", .{i}),
        .pair => |p| print_pair(p),
        .symbol => |s| writer.writeAll(s.data()),
        .vector => |v| print_vector(v),
        .struct_instance => |s| print_struct(s),
        .formals => |f| print_formals(f),
        inline else => |ptr, tag| switch (@typeInfo(@TypeOf(ptr))) {
            .pointer => writer.print("#<" ++ @tagName(tag) ++ " {*}>", .{ptr}),
            else => writer.writeAll("#<" ++ @tagName(tag) ++ ">"),
        },
    };
}

pub fn print(value: SXI) Error!void {
    try print_value(value);
}

pub fn disassemble(c: *sxi.Code) Error!void {
    var ip: usize = 0;
    try writer.print("CODE (len {}) {*}\n", .{ c.instructions.len, c });
    while (ip < c.instructions.len) {
        const op: sxi.Opcode = @enumFromInt(c.instructions[ip]);
        try writer.print("{: >8}:   {s: <24}", .{ ip, @tagName(op) });
        switch (op) {
            .branch, .branch0 => {
                try writer.print("@{}", .{ip + c.instructions[ip + 1]});
                ip += 2;
            },
            .allocate_stack => {
                try writer.print("{}", .{c.instructions[ip + 1]});
                ip += 2;
            },
            .literal => {
                const literal = c.literals[c.instructions[ip + 1]];
                try print_value(literal);
                ip += 2;
            },
            .lookup, .define, .set => {
                const symbol = c.symbols[c.instructions[ip + 1]];
                try writer.writeAll(symbol.data());
                ip += 2;
            },
            .lambda => {
                try print_value(c.literals[c.instructions[ip + 1]]);
                try writer.writeByte(' ');
                try print_value(c.literals[c.instructions[ip + 1] + 1]);
                ip += 2;
            },
            else => {
                ip += 1;
            },
        }
        try writer.writeByte('\n');
    }
    try writer.writeByte('\n');

    for (c.literals) |l| {
        if (l == .code) {
            try disassemble(l.code);
        }
    }
}
