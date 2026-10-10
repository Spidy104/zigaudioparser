//! Small shared primitives for container parsers.
const types = @import("../types.zig");
const SeekableReader = @import("../SeekableReader.zig");

pub const ParseError = types.ParseError || types.IoError;

/// A logical FourCC chunk header with a resolved payload size
pub const ChunkHeader = struct {
    id: [4]u8,
    /// Payload length, excluding the header and alignment padding.
    size: u64,
};

/// Fill out from the current position; premature EOF returns TruncatedData.
pub fn readRequired(source: SeekableReader, out: []u8) ParseError!void {
    source.reader.readSliceAll(out) catch |err| return switch (err) {
        error.EndOfStream => error.TruncatedData,
        else => |e| e,
    };
}
