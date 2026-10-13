//! Sony Wave64: GUID identifiers, inclusive 64-bit sizes and 8-byte alignment.
const std = @import("std");
const types = @import("../types.zig");
const SeekableReader = @import("../SeekableReader.zig");
const common = @import("common.zig");
const wave_format = @import("wave_format.zig");
pub const ParseError = types.ParserError;
pub const FormatChunk = wave_format.FormatChunk;

pub const Guid = [16]u8;
pub const riff_guid: Guid = "riff\x2e\x91\xcf\x11\xa5\xd6\x28\xdb\x04\xc1\x00\x00".*;
pub const wave_guid = guid("wave");
pub const fmt_guid = guid("fmt ");
pub const fact_guid = guid("fact");
pub const data_guid = guid("data");

/// Build a Wave64 WAVE or chunk GUID from its four-character identifier.
fn guid(comptime id: *const [4]u8) Guid {
    return (id.* ++ "\xf3\xac\xd3\x11\x8c\xd1\x00\xc0\x4f\x8e\xdb\x8a").*;
}

pub const ChunkHeader = struct {
    id: Guid,
    /// On-disk size, including the 24-byte chunk header.
    size: u64,
};

pub const FactChunk = struct {
    chunk: ChunkHeader,
    sample_length: u64,
    extra_data: types.DataRange,
};

pub const Wave64Header = struct {
    riff: ChunkHeader,
    fmt: FormatChunk,
    fact: ?FactChunk,
    data: ChunkHeader,
    data_offset: u64,
};

pub const Wave64File = struct {
    header: Wave64Header,
    /// One data segment, trimmed to complete frames for fixed-width audio.
    data: types.AudioData,
    decoded_frames: ?u64,

    /// Return total frames, or null if unknown. Use a result from wave64.parse.
    pub fn frameCount(self: Wave64File) ?u64 {
        if (self.decoded_frames) |frames| return frames;
        return if (self.header.fact) |fact| fact.sample_length else null;
    }

    /// Return metadata and decoding scheme. Use a result from wave64.parse.
    pub fn audio(self: Wave64File) types.ParsedAudio {
        return .{
            .info = .{
                .format = .wave64,
                .sample_rate = self.header.fmt.sample_rate,
                .channels = self.header.fmt.channels,
                .total_frames = self.frameCount(),
            },
            .scheme = self.header.fmt.decodingScheme(.little),
            .data = self.data,
        };
    }
};

/// Return whether block_align gives the encoded byte size of one frame.
fn fixedWidth(fmt: FormatChunk) bool {
    const encoding = fmt.encoding();
    return encoding == .pcm or encoding == .ieee_float or encoding == .alaw or encoding == .mulaw;
}

pub const probe_size = 40; // 40 = RIFF GUID (16) + size (8) + WAVE GUID (16).

/// Recognize a Wave64 prefix, including short headers for parse to validate.
pub fn probe(prefix: []const u8) bool {
    if (prefix.len < 4) return false; // 4 = "riff" prefix of the GUID.
    const riff_length = @min(prefix.len, 16);
    if (!std.mem.eql(u8, prefix[0..riff_length], riff_guid[0..riff_length])) return false;
    if (prefix.len <= 24) return true; // 24 = WAVE GUID offset.
    const wave_length = @min(prefix.len - 24, 16);
    return std.mem.eql(u8, prefix[24..][0..wave_length], wave_guid[0..wave_length]);
}

const Chunk = struct { header: ChunkHeader, data: types.DataRange };

const Iterator = struct {
    source: SeekableReader,
    header: ChunkHeader,
    offset: u64 = 40,
    end: u64,
    data_seen: bool = false,

    /// Validate the file header and declared size, then prepare to iterate chunks.
    fn init(source: SeekableReader) ParseError!Iterator {
        try source.seekTo(0);
        var bytes: [40]u8 = undefined;
        try common.readRequired(source, &bytes);
        if (!std.mem.eql(u8, bytes[0..16], &riff_guid) or
            !std.mem.eql(u8, bytes[24..40], &wave_guid)) return error.UnsupportedFormat;
        const size = std.mem.readInt(u64, bytes[16..24], .little);
        if (size < 40) return error.InvalidData; // 40 = complete file header length.
        if (size > try source.getSize()) return error.TruncatedData;
        return .{ .source = source, .header = .{ .id = riff_guid, .size = size }, .end = size };
    }

    /// Return the next chunk and leave source at its payload; null means EOF.
    fn next(self: *Iterator) ParseError!?Chunk {
        if (self.offset == self.end) return null;
        // 24 = chunk GUID (16) + inclusive size (8).
        if (self.end - self.offset < 24) {
            // Like FFmpeg, accept EOF during the next header after finding data.
            // This also accepts trailing padding without requiring it to exist.
            if (self.data_seen) return null;
            return error.InvalidData;
        }
        try self.source.seekTo(self.offset);
        var bytes: [24]u8 = undefined;
        try common.readRequired(self.source, &bytes);
        const size = std.mem.readInt(u64, bytes[16..24], .little);
        if (size < 24 or size > self.end - self.offset) return error.InvalidData;
        const chunk = Chunk{
            .header = .{ .id = bytes[0..16].*, .size = size },
            .data = .{ .offset = self.offset + 24, .length = size - 24 },
        };
        self.offset += size;
        // Follow FFmpeg's w64_read_header: advance data by its declared size.
        // Writers may include padding in that size or omit it entirely at EOF.
        if (std.mem.eql(u8, &chunk.header.id, &data_guid)) {
            self.data_seen = true;
        } else {
            const padding = (8 - (size & 7)) & 7;
            self.offset += @min(padding, self.end - self.offset);
        }
        return chunk;
    }
};

/// Parse one contiguous audio payload; leaves the source at the audio data.
/// Keep the source unchanged while using returned ranges.
pub fn parse(source: SeekableReader) ParseError!Wave64File {
    var chunks = try Iterator.init(source);
    var fmt: ?FormatChunk = null;
    var fact: ?FactChunk = null;
    var data: ?Chunk = null;
    while (try chunks.next()) |chunk| {
        if (std.mem.eql(u8, &chunk.header.id, &fmt_guid)) {
            if (fmt != null) return error.InvalidData;
            fmt = try wave_format.parseWave64(source, chunk.data);
        } else if (std.mem.eql(u8, &chunk.header.id, &fact_guid)) {
            // 8 = 64-bit sample count.
            if (fact != null or chunk.data.length < 8) return error.InvalidData;
            var count: [8]u8 = undefined;
            try common.readRequired(source, &count);
            fact = .{
                .chunk = chunk.header,
                .sample_length = std.mem.readInt(u64, &count, .little),
                .extra_data = .{ .offset = chunk.data.offset + 8, .length = chunk.data.length - 8 },
            };
        } else if (std.mem.eql(u8, &chunk.header.id, &data_guid)) {
            if (data != null) return error.UnsupportedChunkLayout;
            if (fmt == null) return error.InvalidData;
            data = chunk;
        }
    }
    const format = fmt orelse return error.InvalidData;
    const payload = data orelse return error.InvalidData;
    var audio_data = payload.data;
    if (fixedWidth(format)) {
        // Some writers count alignment bytes in data.size. A fact count can
        // distinguish padding from samples; otherwise retain complete frames.
        const length = if (fact) |f|
            std.math.mul(u64, f.sample_length, format.block_align) catch return error.InvalidData
        else
            audio_data.length - audio_data.length % format.block_align;
        // 7 = maximum padding for 8-byte alignment
        if (length > audio_data.length or audio_data.length - length > 7) return error.InvalidData;
        if (length != audio_data.length and payload.header.size & 7 != 0) return error.InvalidData;
        audio_data.length = length;
    }
    try source.seekTo(audio_data.offset);
    return .{
        .header = .{
            .riff = chunks.header,
            .fmt = format,
            .fact = fact,
            .data = payload.header,
            .data_offset = audio_data.offset,
        },
        .data = types.AudioData.single(.{ .data = audio_data }),
        .decoded_frames = if (fixedWidth(format)) audio_data.length / format.block_align else null,
    };
}
