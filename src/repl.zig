//const SXI = @import("sxi.zig").SXI;
const sxi = @import("sxi.zig");
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
    sxi.init();
    //const env = sxi.gc.make_environment(null);
    const env = @import("builtins.zig").make_root_environment();
    sxi.gc.protect(sxi.wrap(env));

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

        const code = sxi.compile(s, env) catch |err| {
            try writer.print("Compile Error: {any}\n", .{err});
            continue;
        };

        //try @import("print.zig").disassemble(code.code);

        const ret = sxi.evaluate(code) catch |err| {
            try writer.print("Eval Error: {any}\n", .{err});
            continue;
        };

        try sxi.print(ret);
        try writer.writeByte('\n');
    }
}
