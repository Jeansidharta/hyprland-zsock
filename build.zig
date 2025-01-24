const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("hyprland-zsock", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const lib = b.addStaticLibrary(.{
        .name = "hyprland-zsock",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "hyprland-zsock",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    const run_command = b.addRunArtifact(exe);
    run_command.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_command.addArgs(args);
    }

    const run_step = b.step("run", "Run program");
    run_step.dependOn(&run_command.step);
}
