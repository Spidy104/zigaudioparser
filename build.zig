const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("zaudio", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const example = b.addExecutable(.{
        .name = "zaudio-info",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zaudio", .module = module }},
        }),
    });
    b.installArtifact(example);
    const run = b.addRunArtifact(example);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Inspect and decode an audio file").dependOn(&run.step);

    const check = b.step("check", "Compile the example");
    check.dependOn(&example.step);
}
