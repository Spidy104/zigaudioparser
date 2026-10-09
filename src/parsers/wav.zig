//! RIFF WAVE metadata parsing from borrowed seekable input.
// Specification https://www.mmsp.ece.mcgill.ca/Documents/AudioFormats/WAVE/WAVE.html

const std = @import("std");
const types = @import("../types.zig");
const SeekableReader = @import("../SeekableReader.zig");

/// RIFF chunk header.
pub const ChunkHeader = struct {
    id: [4]u8,
    /// Payload bytes, excluding the chunk header and any alignment padding.
    size: u32,
};

/// Outer RIFF header.
pub const RiffHeader = struct {
    chunk: ChunkHeader, // id = "RIFF"; size = file size minus 8
    format: [4]u8, // "WAVE"
};

/// WAVE encoding tag, unknown values preserved.
pub const FormatTag = enum(u16) {
    pcm = 0x0001,
    ieee_float = 0x0003,
    alaw = 0x0006,
    mulaw = 0x0007,
    extensible = 0xfffe,
    _,
};

pub const FormatChunk = struct {
    chunk: ChunkHeader, // id = "fmt "
    audio_format: FormatTag,
    channels: u16,
    sample_rate: u32,
    /// Average encoded bytes per second.
    byte_rate: u32,
    /// Encoded bytes per block.
    block_align: u16,
    /// Storage bits per sample, meaning depends on encoding.
    bits_per_sample: u16,
    /// Extra format data, null for original PCM headers.
    extension: ?FormatExtension = null,

    /// Return format tag, resolves standard extensible subtypes.
    /// Unknown numeric tags are preserved, custom or missing subtypes return null.
    pub fn encoding(self: FormatChunk) ?FormatTag {
        if (self.audio_format != .extensible) return self.audio_format;
        const extension = self.extension orelse return null;
        const ext = switch (extension.payload) {
            .extensible => |ext| ext,
            .codec => return null,
        };
        const suffix = "\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71";
        if (!std.mem.eql(u8, ext.sub_format[2..], suffix)) return null;
        return @enumFromInt(std.mem.readInt(u16, ext.sub_format[0..2], .little));
    }
};

pub const FormatExtension = struct {
    /// Extension bytes, excludes size field.
    size: u16,
    payload: union(enum) {
        /// Source range of extra codec data, may be empty.
        codec: types.DataRange,
        /// Used when audio_format is WAVE_FORMAT_EXTENSIBLE.
        extensible: ExtensibleFormat,
    },
};

pub const ExtensibleFormat = struct {
    /// Significant sample bits within the container specified by bits_per_sample.
    valid_bits_per_sample: u16,
    /// Speaker position bits, zero means unspecified.
    channel_mask: u32,
    /// Full subtype GUID in file byte order, use encoding to resolve a tag.
    sub_format: [16]u8,
    /// Remaining extension bytes, may be empty.
    extra_data: types.DataRange = .{},
};

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
    fmt: FormatChunk,
    /// Decoded frame count from file, may be absent for PCM.
    fact: ?FactChunk = null,
    data: ChunkHeader, // id = "data"; size = encoded audio payload bytes
    /// Actual byte offset of the data payload, after any intervening chunks.
    data_offset: u64,
};

/// WAVE metadata and source ranges.
pub const WavFile = struct {
    header: WavHeader,
    /// Encoded audio bytes, excludes padding.
    data: types.DataRange,

    /// Return metadata and decoding scheme, use a result from wav.parse.
    pub fn audio(self: WavFile) types.ParsedAudio {
        return .{
            .info = .{
                .format = .wav,
                .sample_rate = self.header.fmt.sample_rate,
                .channels = self.header.fmt.channels,
                .total_frames = self.frameCount(),
            },
            .scheme = self.decodingScheme(),
            .data = self.data,
        };
    }

    fn decodingScheme(self: WavFile) types.DecodingScheme {
        const fmt = self.header.fmt;
        const encoding = fmt.encoding() orelse return .unsupported;
        switch (encoding) {
            .alaw => return .alaw,
            .mulaw => return .mulaw,
            .pcm, .ieee_float => {},
            else => return .unsupported,
        }

        const container_bits = @as(u32, fmt.block_align / fmt.channels) * 8;
        var valid_bits = fmt.bits_per_sample;
        if (fmt.audio_format == .extensible) {
            valid_bits = fmt.extension.?.payload.extensible.valid_bits_per_sample;
        } else if (container_bits != (@as(u32, fmt.bits_per_sample) + 7) / 8 * 8) {
            // Some legacy writers use PCM tags for floats in wider containers.
            // Preserve their metadata, but do not guess how to decode them.
            return .unsupported;
        }
        const sample_type: types.PcmSampleType = if (encoding == .ieee_float)
            switch (container_bits) {
                32 => .float32,
                64 => .float64,
                else => return .unsupported,
            }
        else switch (container_bits) {
            8 => .unsigned8,
            16 => .signed16,
            24 => .signed24,
            32 => .signed32,
            64 => .signed64,
            else => return .unsupported,
        };
        return .{ .pcm = .{
            .sample_type = sample_type,
            .byte_order = .little,
            .valid_bits = valid_bits,
        } };
    }

    /// Return total frames, null if unknown. Use a result from wav.parse.
    pub fn frameCount(self: WavFile) ?u64 {
        const encoding = self.header.fmt.encoding();
        if (encoding == .pcm or encoding == .ieee_float or encoding == .alaw or encoding == .mulaw) {
            return self.data.length / self.header.fmt.block_align;
        }
        if (self.header.fact) |fact| return fact.sample_length;
        return null;
    }
};

pub const ParseError = types.ParseError || types.IoError;

/// Read RIFF WAVE metadata from start of input, leaves source at audio data.
/// Accepts a single data chunk, encoding may be unsupported by Decoder.
/// Keep input unchanged while using returned ranges.
/// Source position is unspecified on error.
pub fn parse(source: SeekableReader) ParseError!WavFile {
    const source_size = try source.getSize();
    if (source_size < 12) return error.TruncatedData;
    try source.seekTo(0);
    var header: [12]u8 = undefined;
    try readRequired(source, &header);
    if (!std.mem.eql(u8, header[0..4], "RIFF") or
        !std.mem.eql(u8, header[8..12], "WAVE")) return error.UnsupportedFormat;

    const riff = RiffHeader{
        .chunk = readChunkHeader(header[0..8]),
        .format = header[8..12].*,
    };
    if (riff.chunk.size < 4) return error.InvalidData;
    const end = @as(u64, riff.chunk.size) + 8;
    if (end > source_size) return error.TruncatedData;

    var fmt: ?FormatChunk = null;
    var fact: ?FactChunk = null;
    var data: ?ChunkHeader = null;
    var data_offset: u64 = 0;
    var offset: u64 = 12;
    while (offset < end) {
        if (end - offset < 8) return error.InvalidData;
        try source.seekTo(offset);
        var chunk_bytes: [8]u8 = undefined;
        try readRequired(source, &chunk_bytes);
        const chunk = readChunkHeader(&chunk_bytes);
        offset += 8;
        const padded_size = @as(u64, chunk.size) + (chunk.size & 1);
        if (padded_size > end - offset) return error.InvalidData;

        if (std.mem.eql(u8, &chunk.id, "fmt ")) {
            if (fmt != null) return error.InvalidData;
            fmt = try parseFormat(source, chunk, offset);
        } else if (std.mem.eql(u8, &chunk.id, "fact")) {
            if (fact != null or chunk.size < 4) return error.InvalidData;
            var count: [4]u8 = undefined;
            try readRequired(source, &count);
            fact = .{
                .chunk = chunk,
                .sample_length = std.mem.readInt(u32, &count, .little),
                .extra_data = .{ .offset = offset + 4, .length = chunk.size - 4 },
            };
        } else if (std.mem.eql(u8, &chunk.id, "data")) {
            if (fmt == null or data != null) return error.InvalidData;
            data = chunk;
            data_offset = offset;
        } else if (std.mem.eql(u8, &chunk.id, "LIST")) {
            if (chunk.size < 4) return error.InvalidData;
            var list_type: [4]u8 = undefined;
            try readRequired(source, &list_type);
            if (std.mem.eql(u8, &list_type, "wavl")) return error.UnsupportedChunkLayout;
        }
        offset += padded_size;
    }

    const format = fmt orelse return error.InvalidData;
    const audio = data orelse return error.InvalidData;
    const encoding = format.encoding();
    if (encoding != .pcm and fact == null) return error.InvalidData;
    if (encoding == .pcm or encoding == .ieee_float or encoding == .alaw or encoding == .mulaw) {
        if (audio.size % format.block_align != 0) return error.InvalidData;
    }
    try source.seekTo(data_offset);
    return .{
        .header = .{
            .riff = riff,
            .fmt = format,
            .fact = fact,
            .data = audio,
            .data_offset = data_offset,
        },
        .data = .{ .offset = data_offset, .length = audio.size },
    };
}

fn readRequired(source: SeekableReader, out: []u8) ParseError!void {
    source.reader.readSliceAll(out) catch |err| return switch (err) {
        error.EndOfStream => error.TruncatedData,
        else => |e| e,
    };
}

fn readChunkHeader(bytes: *const [8]u8) ChunkHeader {
    return .{
        .id = bytes[0..4].*,
        .size = std.mem.readInt(u32, bytes[4..8], .little),
    };
}

fn parseFormat(source: SeekableReader, chunk: ChunkHeader, offset: u64) ParseError!FormatChunk {
    if (chunk.size < 16) return error.InvalidData;
    var bytes: [40]u8 = undefined;
    try readRequired(source, bytes[0..16]);
    var fmt = FormatChunk{
        .chunk = chunk,
        .audio_format = @enumFromInt(std.mem.readInt(u16, bytes[0..2], .little)),
        .channels = std.mem.readInt(u16, bytes[2..4], .little),
        .sample_rate = std.mem.readInt(u32, bytes[4..8], .little),
        .byte_rate = std.mem.readInt(u32, bytes[8..12], .little),
        .block_align = std.mem.readInt(u16, bytes[12..14], .little),
        .bits_per_sample = std.mem.readInt(u16, bytes[14..16], .little),
    };
    if (fmt.channels == 0 or fmt.sample_rate == 0 or fmt.block_align == 0 or fmt.byte_rate == 0) {
        return error.InvalidData;
    }
    if (chunk.size != 16) {
        if (chunk.size < 18) return error.InvalidData;
        try readRequired(source, bytes[16..18]);
        const size = std.mem.readInt(u16, bytes[16..18], .little);
        if (@as(u32, size) != chunk.size - 18) return error.InvalidData;
        if (fmt.audio_format == .extensible) {
            if (size < 22) return error.InvalidData;
            try readRequired(source, bytes[18..40]);
            fmt.extension = .{
                .size = size,
                .payload = .{ .extensible = .{
                    .valid_bits_per_sample = std.mem.readInt(u16, bytes[18..20], .little),
                    .channel_mask = std.mem.readInt(u32, bytes[20..24], .little),
                    .sub_format = bytes[24..40].*,
                    .extra_data = .{ .offset = offset + 40, .length = size - 22 },
                } },
            };
        } else {
            fmt.extension = .{ .size = size, .payload = .{ .codec = .{ .offset = offset + 18, .length = size } } };
        }
    } else if (fmt.audio_format != .pcm) {
        return error.InvalidData;
    }

    // Apply sampled-audio rules only to known encodings. Compressed codecs may
    // use bits_per_sample=0 and a block containing many decoded sample frames.
    const encoding = fmt.encoding();
    if (encoding == .pcm or encoding == .ieee_float or encoding == .alaw or encoding == .mulaw) {
        if (fmt.bits_per_sample == 0 or fmt.block_align % fmt.channels != 0) return error.InvalidData;
        const container_bits = @as(u32, fmt.block_align / fmt.channels) * 8;
        if (fmt.audio_format == .extensible) {
            const valid_bits = fmt.extension.?.payload.extensible.valid_bits_per_sample;
            if (fmt.bits_per_sample != container_bits or valid_bits == 0 or valid_bits > container_bits) {
                return error.InvalidData;
            }
        } else if (fmt.bits_per_sample > container_bits) {
            return error.InvalidData;
        }
        // Legacy PCM can declare fewer bits than its storage container, e.g.
        // 24 bits in a 32-bit slot. Retain both values for the eventual decoder.
        if (encoding == .ieee_float) {
            if ((fmt.bits_per_sample != 32 and fmt.bits_per_sample != 64) or
                container_bits != fmt.bits_per_sample) return error.InvalidData;
        }
        if (encoding == .alaw or encoding == .mulaw) {
            if (fmt.bits_per_sample != 8 or container_bits != 8) return error.InvalidData;
        }
        if (@as(u64, fmt.sample_rate) * fmt.block_align != fmt.byte_rate) return error.InvalidData;
    }
    return fmt;
}
