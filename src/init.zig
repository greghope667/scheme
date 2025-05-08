const sxi = @import("sxi.zig");
const SXI = sxi.SXI;

const ports = @import("ports.zig");
const stdout = @import("ports.zig").stdout;
const writer = stdout.writer();

const read = @import("read.zig");

const std = @import("std");

var init_1 = ports.string_literal_port(@embedFile("scheme/init-1.scm"));

pub fn init() !*sxi.Environment {
    @import("ports.zig").init_port_handles();
    @import("read.zig").init_read_symbols();
    @import("compile.zig").init_compile_symbols();

    const env = @import("builtins.zig").make_root_environment();

    read.input_port = &init_1;
    while (true) {
        const expr = sxi.read() catch |err| {
            try writer.print("Read Error: {any}\n", .{err});
            @panic("init-1 Read Error");
        };

        if (expr.eq(sxi.c_eof)) {
            break;
        }

        try writer.writeAll("read: ");
        try sxi.print(expr);
        try writer.writeByte('\n');

        const code = sxi.compile(expr, env) catch |err| {
            try writer.print("Compile Error: {any}\n", .{err});
            @panic("init-1 Compile Error");
        };

        const ret = sxi.evaluate(code) catch |err| {
            try writer.print("Eval Error: {any}\n", .{err});
            @panic("init-1 Eval Error");
        };

        try sxi.print(ret);
        try writer.writeByte('\n');
    }
    try stdout.flush();
    read.input_port = ports.stdin;
    return env;
}
