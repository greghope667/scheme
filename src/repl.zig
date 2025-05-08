//const SXI = @import("sxi.zig").SXI;
const sxi = @import("sxi.zig");
const gc = sxi.gc;
const cons = sxi.cons;
const std = @import("std");

const stdout = @import("ports.zig").stdout;
const writer = stdout.writer();

//pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
//    std.io.getStdErr().writeAll("\nPanic:\n") catch {};
//    std.io.getStdErr().writeAll(message) catch {};
//    std.process.exit(1);
//    while (true) {}
//}

pub fn main() !void {
    const env = try sxi.init();
    sxi.gc.protect(sxi.wrap(env));

    const eval = gc.make_symbol("eval");
    const quote = gc.make_symbol("quote");

    while (true) {
        try std.io.getStdOut().writeAll("> ");
        try stdout.flush();

        const s = sxi.read() catch |err| {
            try writer.print("Read Error: {any}\n", .{err});
            continue;
        };

        if (s.eq(sxi.c_eof)) {
            return;
        }

        try writer.writeAll("read: ");
        try sxi.print(s);
        try writer.writeByte('\n');

        const expr = cons(
            eval,
            cons(
                cons(quote, cons(s, null)),
                cons(env, null),
            ),
        );

        const code = sxi.compile(expr, env) catch |err| {
            try writer.print("Compile Error: {any}\n", .{err});
            continue;
        };

        const ret = sxi.evaluate(code) catch |err| {
            try writer.print("Eval Error: {any}\n", .{err});
            continue;
        };

        try sxi.print(ret);
        try writer.writeByte('\n');
    }
}
