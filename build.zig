const std = @import("std");

pub fn build(builder: *std.Build) !void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});
    const module = builder.addModule(
        "zaudio",
        .{
            .root_source_file = builder.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        },
    );
    const opus = builder.option(bool, "opus", "Enable the libopus backend")
        orelse true;
    const options = builder.addOptions();
    options.addOption(bool, "opus", opus);
    module.addOptions("codec_options", options);
    if (opus) {
        if (builder.lazyDependency("opus", .{})) |dep| {
            @import("build/opus.zig").add(builder, module, dep);
        }
    }
    const example = builder.addExecutable(
        .{
            .name = "zaudio-info",
            .root_module = builder.createModule(
                .{
                    .root_source_file = builder.path("src/main.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "zaudio", .module = module }},
                },
            ),
        },
    );
    builder.installArtifact(example);
    const run = builder.addRunArtifact(example);
    if (builder.args) |args| run.addArgs(args);
    builder.step("run", "Inspect and decode an audio file").dependOn(&run.step);

    const check = builder.step("check", "Compile the example");
    check.dependOn(&example.step);
}
