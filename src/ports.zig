//! I/O ports
//! Roughly the equivalent of a FILE* in C
//! Exposes a Writer interface so the port can be used from zig as well
//! Assumes we have some posix-y IO
const std = @import("std");
const File = std.fs.File;
const Allocator = std.mem.Allocator;

const WriteError = File.WriteError;
const ReadError = File.ReadError;
const SeekError = File.SeekError;
const TellError = File.GetSeekPosError;

const Whence = enum { set, cur, end };

const write_fn = fn (*Port, []const u8) WriteError!usize;
const read_fn = fn (*Port, []u8) ReadError!usize;
//const seek_fn = fn (*Port, isize, Whence) SeekError!void;
//const tell_fn = fn (*Port) TellError!isize;
const close_fn = fn (*Port) void;
const free_fn = fn (*Port, Allocator) void;

const Vtbl = struct {
    write: ?*const write_fn = null,
    read: ?*const read_fn = null,
    //seek: ?*const seek_fn = null,
    //tell: ?*const tell_fn = null,
    close: ?*const close_fn = null,
    free: *const free_fn,
};

const WriteBuffering = enum { none, line, full };

pub const Port = struct {
    vtbl: *const Vtbl,

    input_buffer: []u8 = &.{},
    input_begin: u32 = 0,
    input_end: u32 = 0,

    output_buffer: []u8 = &.{},
    output_end: u32 = 0,
    output_buffering: WriteBuffering = .none,

    // gc_allocated: bool = false,

    pub fn write(self: *Port, bytes: []const u8) WriteError!usize {
        if (self.vtbl.write == null)
            return WriteError.NotOpenForWriting;

        if (self.output_buffering == .none)
            return self.vtbl.write.?(self, bytes);

        if (bytes.len + self.output_end > self.output_buffer.len) {
            try self.flush();
            if (bytes.len > self.output_buffer.len)
                return self.vtbl.write.?(self, bytes);
        }

        const new_end = self.output_end + bytes.len;
        @memcpy(self.output_buffer[self.output_end..new_end], bytes);
        self.output_end = @intCast(new_end);

        if (self.output_buffering == .line) {
            if (std.mem.indexOfScalar(u8, self.output_buffer[0..self.output_end], '\n')) |_|
                try self.flush();
        }

        return bytes.len;
    }

    pub fn flush(self: *Port) WriteError!void {
        if (self.vtbl.write == null)
            return WriteError.NotOpenForWriting;

        var start: u32 = 0;
        while (start < self.output_end) {
            const n = self.vtbl.write.?(
                self,
                self.output_buffer[start..self.output_end],
            ) catch |e| {
                self.output_end = 0;
                return e;
            };
            start += @intCast(n);
        }
        self.output_end = 0;
    }

    pub fn writer(self: *Port) std.io.GenericWriter(*Port, WriteError, Port.write) {
        return .{ .context = self };
    }

    pub fn read(self: *Port, bytes: []u8) ReadError!usize {
        if (self.vtbl.read == null)
            return ReadError.NotOpenForReading;

        const input_ready = self.input_buffer[self.input_begin..self.input_end];
        if (input_ready.len > 0) {
            const length = @min(bytes.len, input_ready.len);
            @memcpy(bytes[0..length], input_ready[0..length]);
            self.input_begin += @intCast(length);
            return length;
        }

        if (bytes.len >= self.input_buffer.len)
            return self.vtbl.read.?(self, bytes);

        self.input_end = @intCast(try self.vtbl.read.?(self, self.input_buffer));
        const length = @min(bytes.len, self.input_end);
        @memcpy(bytes[0..length], self.input_buffer[0..length]);
        self.input_begin = length;
        return length;
    }

    pub fn reader(self: *Port) std.io.GenericReader(*Port, ReadError, Port.read) {
        return .{ .context = self };
    }

    pub fn close(self: *Port) void {
        if (self.output_buffer.len > 0) {
            self.flush() catch {};
        }
        if (self.vtbl.close) |f|
            f(self);
    }

    pub fn free(self: *Port, allocator: Allocator) void {
        //self.close();
        if (self.input_buffer.len > 0)
            allocator.deinit(self.input_buffer);
        if (self.output_buffer.len > 0)
            allocator.deinit(self.output_buffer);
        self.vtbl.free(self, allocator);
    }
};

const FilePort = struct {
    port: Port,
    file: ?File,

    fn read(p: *Port, bytes: []u8) ReadError!usize {
        const self: *FilePort = @fieldParentPtr("port", p);
        return self.file.?.read(bytes);
    }

    fn write(p: *Port, bytes: []const u8) WriteError!usize {
        const self: *FilePort = @fieldParentPtr("port", p);
        return self.file.?.write(bytes);
    }

    fn close(p: *Port) void {
        const self: *FilePort = @fieldParentPtr("port", p);
        self.file.?.close();
        self.file = null;
        self.port.vtbl = &closed_vtbl;
    }

    fn free(p: *Port, allocator: Allocator) void {
        const self: *FilePort = @fieldParentPtr("port", p);
        allocator.destroy(self);
    }

    const closed_vtbl: Vtbl = .{ .free = &free };

    const vtbl: Vtbl = .{
        .read = &read,
        .write = &write,
        .close = &close,
        .free = &free,
    };
};

var stdout_buffer: [4096]u8 = undefined;

var stdout_file: FilePort = .{
    .port = .{
        .vtbl = &FilePort.vtbl,
        .output_buffer = &stdout_buffer,
        .output_buffering = .line,
    },
    .file = undefined,
};

var stderr_file: FilePort = .{
    .port = .{
        .vtbl = &FilePort.vtbl,
    },
    .file = undefined,
};

var stdin_buffer: [4096]u8 = undefined;

var stdin_file: FilePort = .{
    .port = .{
        .input_buffer = &stdin_buffer,
        .vtbl = &FilePort.vtbl,
    },
    .file = undefined,
};

pub const stdout = &stdout_file.port;
pub const stderr = &stderr_file.port;
pub const stdin = &stdin_file.port;

pub fn init_port_handles() void {
    stdout_file.file = std.io.getStdOut();
    stderr_file.file = std.io.getStdErr();
    stdin_file.file = std.io.getStdIn();
}

const StringLiteralPort = struct {
    port: Port,

    fn read(_: *Port, _: []u8) ReadError!usize {
        return 0;
    }

    fn free(p: *Port, allocator: Allocator) void {
        const self: *StringLiteralPort = @fieldParentPtr("port", p);
        allocator.destroy(self);
    }

    const vtbl: Vtbl = .{
        .read = &read,
        .free = &free,
    };
};

pub fn string_literal_port(literal: []const u8) Port {
    return .{
        .input_buffer = @constCast(literal),
        .input_end = @intCast(literal.len),
        .vtbl = &StringLiteralPort.vtbl,
    };
}
