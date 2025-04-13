const sxi = @import("sxi.zig");
const SXI = sxi.SXI;
const gc = @import("gc.zig");

const std = @import("std");
const assert = std.debug.assert;
const Reader = std.io.AnyReader;

// var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var input_buffer: [4096]u8 = undefined;
var input_begin: usize = 0;
var input_end: usize = 0;

// Read from stdin, returns null on EOF
// (panics on other errors)
fn getc() ?u8 {
    if (input_begin < input_end) {
        const ch = input_buffer[input_begin];
        input_begin += 1;
        return ch;
    } else {
        input_begin = 0;
        input_end = std.io.getStdIn().read(&input_buffer) catch @panic("read error");
        if (input_end > 0) {
            input_begin = 1;
            return input_buffer[0];
        } else {
            return null;
        }
    }
}

fn ungetc(ch: u8) void {
    if (input_begin == 0) {
        @panic("ungetc buffer full");
    } else {
        input_begin -= 1;
        input_buffer[input_begin] = ch;
    }
}

const TokenTag = enum {
    eof,
    lparen,
    rparen,
    quote,
    boolean,
    dot,
    integer,
    identifier,
};

const Token = union(TokenTag) {
    eof,
    lparen,
    rparen,
    quote,
    boolean: bool,
    dot,
    integer: isize,
    identifier: *sxi.Symbol,
};

fn isident(ch: u8) bool {
    const cases = comptime blk: {
        var c: [128]bool = @splat(false);
        for ('a'..'z' + 1) |i| {
            c[i] = true;
        }
        for ('A'..'Z' + 1) |i| {
            c[i] = true;
        }
        for ('0'..'9' + 1) |i| {
            c[i] = true;
        }
        for ("!$%&*+-./:<=>?@^_~") |i| {
            c[i] = true;
        }
        break :blk c;
    };
    return ch < cases.len and cases[ch];
}

test "isident" {
    assert(isident('3'));
    assert(isident('@'));
    assert(!isident('#'));
}

const ReadError = error{
    IdentifierTooLong,
    IntegerOutOfRange,
    UnexpectedEOF,
    IllegalEscape,
    UnexpectedCharacter,
    UnexpectedToken,
};

fn read_identifier(first: u8, out: *[128]u8) ReadError!usize {
    var size: usize = 1;
    out[0] = first;

    while (true) {
        if (getc()) |ch| {
            if (isident(ch)) {
                if (size > out.len) {
                    return ReadError.IdentifierTooLong;
                }
                out[size] = ch;
                size += 1;
            } else {
                ungetc(ch);
                return size;
            }
        } else {
            return size;
        }
    }
}

fn read_hash() ReadError!Token {
    return if (getc()) |ch|
        switch (ch) {
            't' => Token{ .boolean = true },
            'f' => Token{ .boolean = false },
            else => ReadError.IllegalEscape,
        }
    else
        ReadError.UnexpectedEOF;
}

fn read_token() ReadError!Token {
    var buffer: [128]u8 = undefined;

    return if (getc()) |ch|
        switch (ch) {
            '(' => .lparen,
            ')' => .rparen,
            '\'' => .quote,
            '#' => read_hash(),
            ' ', '\t', '\r', '\n' => read_token(),
            else => blk: {
                if (!isident(ch)) {
                    return ReadError.UnexpectedCharacter;
                }
                const size = try read_identifier(ch, &buffer);
                const identifier = buffer[0..size];
                break :blk if (std.mem.eql(u8, identifier, "."))
                    .dot
                else if (std.mem.eql(u8, identifier, "'"))
                    .quote
                else if (std.fmt.parseInt(isize, identifier, 0)) |i|
                    .{ .integer = i }
                else |_|
                    .{ .identifier = gc.make_symbol(identifier) };
            },
        }
    else
        .eof;
}

fn read_value_begins(token: Token) ReadError!SXI {
    return switch (token) {
        .boolean => |b| if (b) sxi.c_true else sxi.c_false,
        .eof => sxi.c_eof,
        .identifier => |sym| SXI{ .symbol = sym },
        .integer => |i| SXI{ .integer = i },
        .quote => sxi.wrap(gc.cons(
            sxi.wrap(symbol_quote),
            sxi.wrap(gc.cons(
                try read_value(),
                sxi.c_null,
            )),
        )),
        .lparen => read_list(),
        else => ReadError.UnexpectedToken,
    };
}

fn read_value() ReadError!SXI {
    return read_value_begins(try read_token());
}

fn read_list() ReadError!SXI {
    var head: SXI = sxi.c_null;
    var tail: *SXI = &head;

    while (true) {
        const token = try read_token();
        switch (token) {
            .eof => {
                return ReadError.UnexpectedEOF;
            },
            .rparen => {
                return head;
            },
            .dot => {
                if (tail == &head) {
                    return ReadError.UnexpectedToken;
                }
                tail.* = try read_value();
                const end = try read_token();
                if (!std.meta.eql(end, .rparen)) {
                    return ReadError.UnexpectedToken;
                }
                return head;
            },
            else => {
                var next = gc.cons(
                    try read_value_begins(token),
                    sxi.c_null,
                );
                tail.* = sxi.wrap(next);
                tail = &next.second;
            },
        }
    }
}

pub fn read() ReadError!SXI {
    return read_value();
}

var symbol_quote: *sxi.Symbol = undefined;

export const _init_read_symbols linksection(".init_array") = &(struct {
    fn f() callconv(.C) void {
        symbol_quote = gc.make_symbol("quote");
    }
}.f);
