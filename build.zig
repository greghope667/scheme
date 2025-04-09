const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("sxi", .{
        .root_source_file = b.path("src/repl.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "sxi",
        .root_module = module,
    });
    //exe.linkLibC();
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    b.step("run", "Run").dependOn(&run_exe.step);

    // Extra 'check' executable that never gets installed,
    // used for build-on-save editor support
    const check_exe = b.addExecutable(.{
        .name = "sxi",
        .root_module = module,
    });
    const check = b.step("check", "Check Build");
    check.dependOn(&check_exe.step);
}
