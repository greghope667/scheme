const std = @import("std");
const assert = std.debug.assert;

const sxi = @import("sxi.zig");
const SXI = sxi.SXI;
const Opcode = sxi.Opcode;
const OpcodeInt = sxi.OpcodeInt;
const allocator = sxi.allocator;

const gc = @import("gc.zig");

const IP = [*]OpcodeInt;
const Env = *sxi.Environment;

const EvalError = error{
    NotDefined,
    NotCallable,
    OutOfMemory,
    NotImplemented,
    InvalidArguments,
    Overflow,
    DivideByZero,
};
//const Err = EvalError;
const Err = anyerror;

pub const Continuation = struct {
    code: *sxi.Code,
    return_address: IP,
    stack: *sxi.Vector,
    stack_used: usize,
    stack_limit: usize,
    environment: Env,
    next: *Continuation,
};

//pub const Opcode = enum(OI) {
//    0 allocate_stack,
//    1 lookup_callable,
//    2 lookup_variable,
//    3 call,
//    4 tailcall,
//    5 literal,
//    6 ret,
//    7 branch,
//    8 branch0,
//    9 push,
//   10 define,
//   11 exit,
//   12 lambda,
//   13 push_callable,
//};

inline fn fetch(ip: IP) Opcode {
    //std.debug.print("{*} {}\n", .{ ip, ip[0] });
    return @enumFromInt(ip[0]);
}

fn bind_lambda(l: *sxi.Lambda, args: []SXI) Err!Env {
    if (l.arguments.names.len != args.len) {
        return Err.InvalidArguments;
    }

    const env = gc.make_environment(l.capture);
    //try env.entries.resize(allocator, args.len);
    env.map.items = try allocator.alloc(sxi.Environment.Entry, args.len);
    env.map.capacity = @intCast(args.len);

    for (env.map.items, 0..) |*entry, i| {
        entry.* = .{ .key = l.arguments.names[i], .value = args[i] };
    }
    return env;
}

fn eval_(code_: *sxi.Code, cont_: *sxi.Continuation, env_: Env) Err!SXI {
    var code = code_;
    var cont = cont_;
    var env = env_;
    var tos = sxi.c_void;
    var stack: *sxi.Vector = gc.make_vector();
    var ip: IP = @ptrCast(&code.instructions[0]);

    next: switch (fetch(ip)) {
        .allocate_stack => {
            const limit = ip[1];
            stack = gc.make_vector();

            // These are MUCH slower, need to investigate why (type erasure of allocator?)
            //try stack.data.ensureTotalCapacity(allocator, limit);
            //stack.data = try .initCapacity(allocator, limit);
            stack.data.items = try allocator.alloc(SXI, limit);
            stack.data.items.len = 0;
            stack.data.capacity = limit;

            ip += 2;
            continue :next fetch(ip);
        },

        .allocate_cont => {
            const next_cont = gc.alloc(.continuation);
            next_cont.* = .{
                .code = code,
                .stack = stack,
                .return_address = undefined,
                .stack_used = stack.data.items.len,
                .stack_limit = stack.data.capacity,
                .environment = env,
                .next = cont,
            };
            cont = next_cont;
            ip += 1;
            continue :next fetch(ip);
        },

        .ret => {
            if (gc.allocation_counter > 4096) {
                @branchHint(.unlikely);
                @call(.never_inline, gc.run, .{&[2]SXI{ sxi.wrap(cont), tos }});
            }

            code = cont.code;
            stack = cont.stack;
            ip = cont.return_address;
            env = cont.environment;
            cont = cont.next;
            continue :next fetch(ip);
        },

        .call => {
            cont.return_address = ip + 1;
            continue :next .tailcall;
        },

        .tailcall => {
            const caller_args = stack.data.items[1..];
            switch (stack.data.items[0]) {
                .lambda => |l| {
                    env = try @call(.auto, bind_lambda, .{ l, caller_args });
                    code = l.code;
                    ip = @ptrCast(&code.instructions[0]);

                    continue :next fetch(ip);
                },

                .function_n => |f| {
                    tos = try f(caller_args);
                    continue :next .ret;
                },

                .function_1 => |f| {
                    if (caller_args.len != 1) {
                        return Err.InvalidArguments;
                    }
                    tos = try f(caller_args[0]);
                    continue :next .ret;
                },

                .function_s => |f| switch (f) {
                    .values => {
                        if (cont.return_address[0] != @intFromEnum(Opcode.push))
                            return Err.InvalidArguments;
                        cont.return_address += 1;
                        const caller_stack = &cont.stack.data;
                        try caller_stack.ensureTotalCapacityPrecise(allocator, caller_stack.capacity + caller_args.len);
                        caller_stack.appendSliceAssumeCapacity(caller_args);
                        continue :next .ret;
                    },

                    .apply => {
                        const tail = stack.data.getLast();
                        _ = stack.data.pop();
                        _ = stack.data.orderedRemove(0);
                        var iter = @import("builtins.zig").listerate(tail);
                        while (try iter.next()) |v| {
                            try stack.data.append(allocator, v);
                        }
                        continue :next .tailcall;
                    },

                    .current_env => {
                        if (caller_args.len != 0)
                            return Err.InvalidArguments;
                        tos = sxi.wrap(env);
                        continue :next .ret;
                    },
                },

                else => {
                    //std.debug.print("Cannot call: {s}\n", .{@tagName(tag)});
                    return Err.NotCallable;
                },
            }
        },

        .push_callable, .push => {
            stack.data.appendAssumeCapacity(tos);
            ip += 1;
            continue :next fetch(ip);
        },

        .literal => {
            tos = code.literals[ip[1]];
            ip += 2;
            continue :next fetch(ip);
        },

        .exit => {
            return tos;
        },

        .lookup_variable => {
            tos = env.lookup(code.symbols[ip[1]]) orelse {
                //std.debug.print("Not defined: {s}\n", .{code.symbols[ip[1]].data()});
                return Err.NotDefined;
            };
            ip += 2;
            continue :next fetch(ip);
        },

        .lookup_callable => {
            tos = env.lookup(code.symbols[ip[1]]) orelse {
                //std.debug.print("Not defined: {s}\n", .{code.symbols[ip[1]].data()});
                return Err.NotDefined;
            };
            stack.data.appendAssumeCapacity(tos);
            ip += 2;
            continue :next fetch(ip);
        },

        .define => {
            env.define(code.symbols[ip[1]], tos);
            ip += 2;
            continue :next fetch(ip);
        },

        .branch => {
            ip += ip[1];
            continue :next fetch(ip);
        },

        .branch0 => {
            ip += if (tos.eq(sxi.c_false)) ip[1] else 2;
            continue :next fetch(ip);
        },

        .lambda => {
            const lambda = gc.alloc(.lambda);
            lambda.* = .{
                .capture = env,
                .arguments = code.literals[ip[1]].formals,
                .code = code.literals[ip[1] + 1].code,
            };
            tos = sxi.wrap(lambda);
            ip += 2;
            continue :next fetch(ip);
        },
    }
}

pub fn evaluate(code: *sxi.Lambda) Err!SXI {
    if (code.arguments.names.len > 0)
        return Err.InvalidArguments;

    const exit = try allocator.alloc(OpcodeInt, 1);
    exit[0] = @intFromEnum(Opcode.exit);

    const exit_thunk = gc.alloc(.code);
    exit_thunk.* = .{
        .instructions = exit,
        .symbols = &.{},
        .literals = &.{},
    };

    const cont = gc.alloc(.continuation);
    cont.* = .{
        .code = exit_thunk,
        .return_address = @ptrCast(&exit[0]),
        .stack = gc.make_vector(),
        .stack_used = 0,
        .stack_limit = 0,
        .environment = code.capture,
        .next = cont,
    };

    return @call(.never_inline, eval_, .{ code.code, cont, code.capture });
}
