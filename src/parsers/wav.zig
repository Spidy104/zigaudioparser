//! RIFF, RIFX, RF64 and BW64 WAVE metadata parsing
// Specification https://www.mmsp.ece.mcgill.ca/Documents/AudioFormats/WAVE/WAVE.html

const std = @import("std");
const types = @import("../types.zig");
const SeekableReader = @import("../SeekableReader.zig");

const framing = @import("riff.zig");
const common = @import("common.zig");
const readRequired = common.readRequired;

/// Resolved headers; chunk sizes are u64 payload lengths, not raw wire fields.
pub const ChunkHeader = framing.ChunkHeader;
pub const RiffHeader = framing.RiffHeader;
pub const DataSize64 = framing.DataSize64;

const wave_format = @import("wave_format.zig");
pub const FormatTag = wave_format.FormatTag;
pub const FormatChunk = wave_format.FormatChunk;
pub const FormatExtension = wave_format.FormatExtension;
pub const ExtensibleFormat = wave_format.ExtensibleFormat;

pub const FactChunk = struct {
    chunk: ChunkHeader, // id = "fact"; size >= 4
    /// Decoded samples per channel, including for compressed encodings.
    sample_length: u32,
    /// Source range following sample_length, if any.
    extra_data: types.DataRange = .{},
};

/// Metadata collected by walking WAVE chunks.
pub const WavHeader = struct {
    riff: RiffHeader,
    ds64: ?DataSize64 = null,
    fmt: FormatChunk,
    /// Decoded frame count from file, may be absent for PCM.
    fact: ?FactChunk = null,
    data: ChunkHeader, // data or LIST/wavl chunk; size excludes its header and padding.
    /// Actual byte offset of the data or LIST payload.
    data_offset: u64,
};

/// WAVE metadata and source ranges.
pub const WavFile = struct {
    header: WavHeader,
    data: types.AudioData,
    /// Frame count derived from fixed-width segments, including silence.
    decoded_frames: ?u64,

    /// Return metadata and decoding scheme, use a result from wav.parse.
    pub fn audio(self: WavFile) types.ParsedAudio {
        return .{
            .info = .{
                .format = .wav,
                .sample_rate = self.header.fmt.sample_rate,
                .channels = self.header.fmt.channels,
                .total_frames = self.frameCount(),
            },
            .scheme = self.header.fmt.decodingScheme(self.header.riff.byteOrder()),
            .data = self.data,
        };
    }

    /// Return total frames, null if unknown. Use a result from wav.parse.
    pub fn frameCount(self: WavFile) ?u64 {
        if (self.decoded_frames) |frames| return frames;
        if (self.header.ds64) |ds64| {
            if (ds64.sample_count) |count| {
                if (count != 0) return count;
            }
        }
        if (self.header.fact) |fact| {
            if (self.header.ds64 == null or fact.sample_length != std.math.maxInt(u32)) return fact.sample_length;
        }
        return null;
    }
};

pub const ParseError = types.ParserError;

/// Bytes useful for identifying this container family. A recognized short
/// prefix is dispatched so parse() can report a truncated header.
pub const probe_size = 12; // 12 = chunk ID + size + WAVE form type.

/// Recognize a RIFF-family WAVE prefix, including short headers for parse to validate.
pub fn probe(prefix: []const u8) bool {
    if (prefix.len < 4) return false; // 4 = FourCC length.
    const id = prefix[0..4];
    if (!std.mem.eql(u8, id, "RIFF") and
        !std.mem.eql(u8, id, "RIFX") and
        !std.mem.eql(u8, id, "RF64") and
        !std.mem.eql(u8, id, "BW64")) return false;
    // 8..12 = WAVE form type after the chunk ID and size.
    return prefix.len < probe_size or std.mem.eql(u8, prefix[8..12], "WAVE");
}

/// Parse one data chunk or a RIFF/RIFX wavl sequence; encoding may be unsupported.
/// Leaves source at the first data segment, or the audio payload if none exists.
/// Keep input unchanged for returned ranges. Source position is unspecified on error.
pub fn parse(source: SeekableReader) ParseError!WavFile {
    var chunks = try framing.Iterator.init(source);
    if (!std.mem.eql(u8, &chunks.header.format, "WAVE")) return error.UnsupportedFormat;

    var fmt: ?FormatChunk = null;
    var fact: ?FactChunk = null;
    var data: ?ChunkHeader = null;
    var data_offset: u64 = 0;
    var audio_data: ?types.AudioData = null;
    while (try chunks.next()) |framed| {
        const chunk = framed.header;
        const offset = framed.data.offset;

        if (std.mem.eql(u8, &chunk.id, "fmt ")) {
            if (fmt != null) return error.InvalidData;
            fmt = try wave_format.parse(source, framed.data, chunks.header.byteOrder());
        } else if (std.mem.eql(u8, &chunk.id, "fact")) {
            // 4 = 32-bit sample count.
            if (fact != null or chunk.size < 4) return error.InvalidData;
            var count: [4]u8 = undefined;
            try readRequired(source, &count);
            fact = .{
                .chunk = chunk,
                .sample_length = std.mem.readInt(u32, &count, chunks.header.byteOrder()),
                .extra_data = .{ .offset = offset + 4, .length = chunk.size - 4 },
            };
        } else if (std.mem.eql(u8, &chunk.id, "data")) {
            if (data != null) return error.UnsupportedChunkLayout;
            if (fmt == null) return error.InvalidData;
            data = chunk;
            data_offset = offset;
            audio_data = types.AudioData.single(.{ .data = framed.data });
        } else if (std.mem.eql(u8, &chunk.id, "LIST")) {
            if (chunk.size < 4) return error.InvalidData; // 4 = LIST type FourCC.
            var list_type: [4]u8 = undefined;
            try readRequired(source, &list_type);
            if (std.mem.eql(u8, &list_type, "wavl")) {
                if (data != null) return error.UnsupportedChunkLayout;
                // Nested ds64 size overrides are not supported.
                if (chunks.ds64 != null) return error.UnsupportedChunkLayout;
                if (fmt == null) return error.InvalidData;
                data = chunk;
                data_offset = offset;
                audio_data = .{ .layout = .{ .wavl = .{
                    .children = .{ .offset = offset + 4, .length = chunk.size - 4 },
                    .byte_order = chunks.header.byteOrder(),
                } } };
            }
        }
    }

    const format = fmt orelse return error.InvalidData;
    const audio = data orelse return error.InvalidData;
    const layout = audio_data.?;
    const encoding = format.encoding();
    const segmented = layout.layout == .wavl;
    if ((encoding != .pcm or segmented) and fact == null and chunks.ds64 == null) return error.InvalidData;
    const fixed_width = encoding == .pcm or encoding == .ieee_float or encoding == .alaw or encoding == .mulaw;
    var frames: u64 = 0;
    var first_data: ?u64 = null;
    var segments = layout.iterate(source);
    while (try segments.next()) |segment| {
        if (segment == .data and first_data == null) first_data = segment.data.offset;
        if (fixed_width) {
            frames = std.math.add(u64, frames, try segment.frameCount(format.block_align)) catch return error.InvalidData;
        }
    }
    if (segmented and fixed_width and fact.?.sample_length != frames) return error.InvalidData;
    try source.seekTo(first_data orelse data_offset);
    return .{
        .header = .{
            .riff = chunks.header,
            .ds64 = chunks.ds64,
            .fmt = format,
            .fact = fact,
            .data = audio,
            .data_offset = data_offset,
        },
        .data = layout,
        .decoded_frames = if (fixed_width) frames else null,
    };
}
