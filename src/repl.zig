//const SXI = @import("sxi.zig").SXI;
const sxi = @import("sxi.zig");
const std = @import("std");

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    std.io.getStdErr().writeAll("\nPanic:\n") catch {};
    std.io.getStdErr().writeAll(message) catch {};
    std.process.exit(1);
    while (true) {}
}

pub fn main() !void {
    //const env = sxi.gc.make_environment(null);
    const env = @import("eval.zig").make_root_environment();

    while (true) {
        try std.io.getStdOut().writeAll("\n> ");

        const s = sxi.read() catch |err| {
            try std.io.getStdOut().writer().print("Read Error: {any}\n", .{err});
            continue;
        };

        if (s.eq(sxi.c_eof)) {
            return;
        }

        if (!s.eq(sxi.c_void)) {
            try sxi.print(s);
            try std.io.getStdOut().writeAll("\n");
        }

        const code = sxi.compile(s) catch |err| {
            try std.io.getStdErr().writer().print("Compile Error: {any}\n", .{err});
            continue;
        };

        try @import("print.zig").print_code(code);

        const ret = sxi.evaluate(code, env) catch |err| {
            try std.io.getStdErr().writer().print("Eval Error: {any}\n", .{err});
            continue;
        };

        try sxi.print(ret);
    }
}
