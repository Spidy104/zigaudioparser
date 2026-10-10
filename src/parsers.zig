//! Container detection and metadata parsing.
const types = @import("types.zig");
const SeekableReader = @import("SeekableReader.zig");
const common = @import("parsers/common.zig");
pub const wav = @import("parsers/wav.zig");
pub const wave64 = @import("parsers/wave64.zig");

// Register parser modules here. Each supplies probe_size, probe(prefix), and
// parse(source), whose container-specific result exposes audio(): ParsedAudio.
const containers = .{ wav, wave64 };
const probe_size = blk: {
    var size: usize = 0;
    for (containers) |container| size = @max(size, container.probe_size);
    break :blk size;
};

/// Read audio metadata from start of input. The result describes audio segments;
/// initialize a decoder or segment iterator before reading samples.
/// Keep input unchanged while using returned ranges. Source position is unspecified on error.
pub fn parse(source: SeekableReader) (types.ParseError || types.IoError)!types.ParsedAudio {
    const size: usize = @intCast(@min(try source.getSize(), probe_size));
    try source.seekTo(0);
    var prefix: [probe_size]u8 = undefined;
    try common.readRequired(source, prefix[0..size]);
    return dispatch(source, prefix[0..size]);
}

fn dispatch(source: SeekableReader, prefix: []const u8) common.ParseError!types.ParsedAudio {
    inline for (containers) |container| {
        if (container.probe(prefix)) {
            try source.seekTo(0);
            return (try container.parse(source)).audio();
        }
    }
    return error.UnsupportedFormat;
}
