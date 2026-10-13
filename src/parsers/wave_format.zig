//! Parses WAVE fmt payloads and selects decoding schemes.
const std = @import("std");
const types = @import("../types.zig");
const SeekableReader = @import("../SeekableReader.zig");
const common = @import("common.zig");
const ChunkHeader = common.ChunkHeader;
const readRequired = common.readRequired;
pub const ParseError = types.ParserError;

/// WAVE encoding tag; unknown values are preserved.
pub const FormatTag = enum(u16) {
    pcm = 0x0001,
    ieee_float = 0x0003,
    alaw = 0x0006,
    mulaw = 0x0007,
    extensible = 0xfffe,
    _,
};

/// Parsed fmt fields and borrowed extension ranges.
pub const FormatChunk = struct {
    chunk: ChunkHeader, // id = "fmt "
    audio_format: FormatTag,
    channels: u16,
    sample_rate: u32,
    /// Average encoded bytes per second.
    byte_rate: u32,
    /// Encoded bytes per block.
    block_align: u16,
    /// Declared bits per sample; meaning depends on encoding.
    bits_per_sample: u16,
    /// Extra format data, or null when no extension is present.
    extension: ?FormatExtension = null,
    byte_order: std.builtin.Endian = .little,

    /// Return the encoding tag, resolving standard extensible subtypes.
    /// Preserve unknown tags; return null for custom or missing subtypes.
    pub fn encoding(self: FormatChunk) ?FormatTag {
        if (self.audio_format != .extensible) return self.audio_format;
        const extension = self.extension orelse return null;
        const ext = switch (extension.payload) {
            .extensible => |ext| ext,
            .codec => return null,
        };
        const guid = ext.sub_format;
        // 4..6 = GUID Data2; 6..8 = Data3; 8..16 = Data4.
        if (std.mem.readInt(u16, guid[4..6], self.byte_order) != 0 or
            std.mem.readInt(u16, guid[6..8], self.byte_order) != 0x0010 or
            !std.mem.eql(u8, guid[8..], "\x80\x00\x00\xaa\x00\x38\x9b\x71")) return null;
        const tag = std.mem.readInt(u32, guid[0..4], self.byte_order);
        if (tag > std.math.maxInt(u16)) return null;
        return @enumFromInt(@as(u16, @intCast(tag)));
    }

    /// Select a decoding scheme for a validated format and the sample byte order.
    /// Return unsupported for unknown encodings or unsupported sample layouts.
    pub fn decodingScheme(fmt: FormatChunk, byte_order: std.builtin.Endian) types.DecodingScheme {
        const tag = fmt.encoding() orelse return .unsupported;
        switch (tag) {
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
            // Wider PCM containers may hold mislabeled floats; decoding is ambiguous.
            return .unsupported;
        }
        const sample_type: types.PcmSampleType = if (tag == .ieee_float)
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
            .byte_order = byte_order,
            .valid_bits = valid_bits,
        } };
    }
};

/// Extra fmt data following the base fields.
pub const FormatExtension = struct {
    /// Extension length in bytes, excluding the size field.
    size: u16,
    payload: union(enum) {
        /// Borrowed codec data; may be empty.
        codec: types.DataRange,
        /// Fields for the extensible format tag.
        extensible: ExtensibleFormat,
    },
};

/// Sample layout and subtype for the extensible format tag.
pub const ExtensibleFormat = struct {
    /// Significant bits per sample within bits_per_sample storage bits.
    valid_bits_per_sample: u16,
    /// Speaker position bits; zero means unspecified.
    channel_mask: u32,
    /// Subtype GUID in file byte order; use FormatChunk.encoding to resolve it.
    sub_format: [16]u8,
    /// Borrowed trailing extension data; may be empty.
    extra_data: types.DataRange = .{},
};

/// Parse a fmt payload, excluding its chunk header.
/// Leaves source within the payload. Keep input unchanged to use borrowed ranges.
pub fn parse(source: SeekableReader, data: types.DataRange, byte_order: std.builtin.Endian) ParseError!FormatChunk {
    return parsePayload(source, data, byte_order, false);
}

/// Like parse, using little-endian fields and allowing Wave64 alignment padding.
pub fn parseWave64(source: SeekableReader, data: types.DataRange) ParseError!FormatChunk {
    return parsePayload(source, data, .little, true);
}

/// Parse and validate fmt fields; padded allows trailing bytes up to 8-byte alignment.
fn parsePayload(source: SeekableReader, data: types.DataRange, byte_order: std.builtin.Endian, padded: bool) ParseError!FormatChunk {
    const chunk = ChunkHeader{ .id = "fmt ".*, .size = data.length };
    const offset = data.offset;
    _ = try data.end();
    if (chunk.size < 16) return error.InvalidData; // 16 = base fmt fields.
    try source.seekTo(offset);
    var bytes: [40]u8 = undefined;
    try readRequired(source, bytes[0..16]);
    var fmt = FormatChunk{
        .chunk = chunk,
        .byte_order = byte_order,
        .audio_format = @enumFromInt(std.mem.readInt(u16, bytes[0..2], byte_order)),
        .channels = std.mem.readInt(u16, bytes[2..4], byte_order),
        .sample_rate = std.mem.readInt(u32, bytes[4..8], byte_order),
        .byte_rate = std.mem.readInt(u32, bytes[8..12], byte_order),
        .block_align = std.mem.readInt(u16, bytes[12..14], byte_order),
        .bits_per_sample = std.mem.readInt(u16, bytes[14..16], byte_order),
    };
    if (fmt.channels == 0 or fmt.sample_rate == 0 or fmt.block_align == 0 or fmt.byte_rate == 0) {
        return error.InvalidData;
    }
    if (chunk.size != 16) {
        if (chunk.size < 18) return error.InvalidData; // 18 = base fmt fields + 16-bit extension size.
        try readRequired(source, bytes[16..18]);
        const size = std.mem.readInt(u16, bytes[16..18], byte_order);
        const format_size = @as(u64, size) + 18;
        if (format_size > chunk.size) return error.InvalidData;
        // 7 = rounding allowance for Wave64's 8-byte alignment.
        if (format_size != chunk.size and
            (!padded or chunk.size != (format_size + 7) & ~@as(u64, 7))) return error.InvalidData;
        if (fmt.audio_format == .extensible) {
            if (size < 22) return error.InvalidData; // 22 = valid bits (2) + channel mask (4) + GUID (16).
            // 18..40 = fixed WAVE_FORMAT_EXTENSIBLE extension.
            try readRequired(source, bytes[18..40]);
            fmt.extension = .{
                .size = size,
                .payload = .{ .extensible = .{
                    .valid_bits_per_sample = std.mem.readInt(u16, bytes[18..20], byte_order),
                    .channel_mask = std.mem.readInt(u32, bytes[20..24], byte_order),
                    .sub_format = bytes[24..40].*,
                    .extra_data = .{ .offset = offset + 40, .length = size - 22 },
                } },
            };
        } else {
            fmt.extension = .{ .size = size, .payload = .{ .codec = .{ .offset = offset + 18, .length = size } } };
        }
    } else if (fmt.audio_format != .pcm and fmt.audio_format != .ieee_float and
        fmt.audio_format != .alaw and fmt.audio_format != .mulaw)
    {
        return error.InvalidData;
    }

    // Apply sampled-audio rules to known encodings.
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
        // Preserve legacy PCM bit depths smaller than their storage slots.
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
