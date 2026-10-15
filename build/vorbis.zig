//! build core libvorbis 1.3.7 without wrapper libraries or libogg.
const std = @import("std");
pub fn add(
    module: *std.Build.Module,
    dep: *std.Build.Dependency,
    compat: std.Build.LazyPath,
) void {
    module.addIncludePath(compat);
    module.addIncludePath(dep.path("include"));
    module.addIncludePath(dep.path("lib"));
    module.addCSourceFiles(
        .{
            .root = dep.path("lib"),
            .files = &.{
                "mdct.c",
                "smallft.c",
                "block.c",
                "envelope.c",
                "window.c",
                "lsp.c",
                "lpc.c",
                "analysis.c",
                "synthesis.c",
                "psy.c",
                "info.c",
                "floor1.c",
                "floor0.c",
                "res0.c",
                "mapping0.c",
                "registry.c",
                "codebook.c",
                "sharedbook.c",
                "lookup.c",
                "bitrate.c",
            },
            .flags = &.{ "-std=c99", "-DNDEBUG", "-Dalloca=__builtin_alloca" },
        },
    );
    module.link_libc = true;
}
