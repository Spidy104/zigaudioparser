//! Container detection and metadata parsing.
const std = @import("std");
const types = @import("types.zig");
const SeekableReader = @import("SeekableReader.zig");
pub const wav = @import("parsers/wav.zig");

/// Read audio metadata from start of input, leaves source at audio data.
/// Encoding may be unsupported by Decoder. Keep input unchanged while using
/// returned ranges. Source position is unspecified on error.
pub fn parse(source: SeekableReader) (types.ParseError || types.IoError)!types.ParsedAudio {
    if (try source.getSize() < 4) return error.UnsupportedFormat;
    try source.seekTo(0);
    var signature: [4]u8 = undefined;
    source.reader.readSliceAll(&signature) catch |err| return switch (err) {
        error.EndOfStream => error.TruncatedData,
        else => |e| e,
    };
    if (std.mem.eql(u8, &signature, "RIFF")) {
        return (try wav.parse(source)).audio();
    }
    return error.UnsupportedFormat;
}
