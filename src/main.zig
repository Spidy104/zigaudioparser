//! Example client: inspect a file and consume its decoded audio in chunks.
const std = @import("std");
const zaudio = @import("zaudio");

/// Decode the file named by the sole argument and print its format and frame count.
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) {
        std.debug.print("Usage: zaudio-info <audio-file>\n", .{});
        std.process.exit(1);
    }
    const file = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer file.close(init.io);
    var input_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(init.io, &input_buffer);
    var decoder = try zaudio.Decoder.init(allocator, zaudio.Source.fromFile(&reader));
    defer decoder.deinit();
    const info = decoder.info();
    const samples = try allocator.alloc(f32, @as(usize, info.channels) * 1024);
    defer allocator.free(samples);
    var frames: u64 = 0;
    while (true) {
        const count = try decoder.read(samples);
        if (count == 0) break;
        frames += count;
    }
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    try stdout.interface.print("{s}: {d} Hz, {d} channels, {d} frames decoded\n", .{
        @tagName(info.format), info.sample_rate, info.channels, frames,
    });
    try stdout.interface.flush();
}
