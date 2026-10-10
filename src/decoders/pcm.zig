//! Container-independent PCM sample decoding into interleaved f32 output.
//! Integer samples are normalized to [-1, 1]
const std = @import("std");
const types = @import("../types.zig");
const SeekableReader = @import("../SeekableReader.zig");

pub const Decoder = struct {
    source: SeekableReader,
    data: types.DataRange,
    format: types.PcmFormat,
    channels: u16,
    frame_offset: u64 = 0,
    // A failed seek is replayed by read until a later seek succeeds.
    failure: ?(types.ReadError || types.SeekError || error{TruncatedData}) = null,

    /// Validate the PCM range and seek to its start; data must contain whole frames.
    /// Borrows source: keep its reader and buffer in place and input open and unchanged.
    pub fn init(source: SeekableReader, data: types.DataRange, channels: u16, format: types.PcmFormat) (types.DecodeError || types.SeekError || types.SizeError)!Decoder {
        if (channels == 0) return error.InvalidData;
        const frame_bytes = @as(usize, channels) * format.sample_type.byteSize();
        if (data.length % frame_bytes != 0) return error.InvalidData;
        try validateFormat(format);
        if (try data.end() > try source.getSize()) return error.TruncatedData;
        try source.seekTo(data.offset);
        return .{ .source = source, .data = data, .format = format, .channels = channels };
    }

    /// Return the total number of frames in the PCM range.
    pub fn frameCount(self: Decoder) u64 {
        return self.data.length / (@as(u64, self.channels) * self.format.sample_type.byteSize());
    }

    /// Seek to an absolute frame within the PCM range, clearing prior errors on success.
    /// frameCount() is EOF; larger positions return OutOfRange.
    pub fn seekFrame(self: *Decoder, frame: u64) (types.DecodeError || types.SeekError)!void {
        if (frame > self.frameCount()) return error.OutOfRange;
        // init checked the range end. An in-range frame cannot overflow it.
        const offset = self.data.offset + frame * self.channels * self.format.sample_type.byteSize();
        self.source.seekTo(offset) catch |err| {
            self.failure = err;
            return err;
        };
        self.frame_offset = frame;
        self.failure = null;
    }

    /// Returns frames written, leaving the rest of out untouched. Zero is EOF.
    /// out must be nonempty and its length a multiple of the channel count.
    /// After an input error, discard output and seek successfully before reading again.
    pub fn read(self: *Decoder, out: []f32) (types.DecodeError || types.ReadError || types.SeekError)!usize {
        if (out.len == 0 or out.len % self.channels != 0) return error.InvalidBufferSize;
        if (self.failure) |err| return err;
        const sample_bytes = self.format.sample_type.byteSize();
        const frames: usize = @intCast(@min(out.len / self.channels, self.frameCount() - self.frame_offset));
        const samples = frames * self.channels;
        var scratch: [8192]u8 = undefined;
        var written: usize = 0;
        while (written < samples) {
            const count = @min(samples - written, scratch.len / sample_bytes);
            const input = scratch[0 .. count * sample_bytes];
            self.source.reader.readSliceAll(input) catch |err| {
                const failure = switch (err) {
                    error.EndOfStream => error.TruncatedData,
                    else => |e| e,
                };
                self.failure = failure;
                return failure;
            };
            for (out[written..][0..count], 0..) |*sample, i| {
                sample.* = decodeSample(input[i * sample_bytes ..][0..sample_bytes], self.format);
            }
            written += count;
        }
        self.frame_offset += frames;
        return frames;
    }
};

/// Return InvalidData if valid_bits is zero or exceeds the sample storage width.
pub fn validateFormat(format: types.PcmFormat) error{InvalidData}!void {
    if (format.valid_bits) |valid_bits| {
        if (valid_bits == 0 or valid_bits > format.sample_type.byteSize() * 8) return error.InvalidData;
    }
}

/// Convert one encoded sample to f32; bytes must contain a full sample.
fn decodeSample(bytes: []const u8, format: types.PcmFormat) f32 {
    const endian = format.byte_order;
    return switch (format.sample_type) {
        .unsigned8 => (@as(f32, @floatFromInt(bytes[0])) - 128.0) / 128.0,
        .signed8 => @as(f32, @floatFromInt(@as(i8, @bitCast(bytes[0])))) / 0x1p7,
        .signed16 => @as(f32, @floatFromInt(std.mem.readInt(i16, bytes[0..2], endian))) / 0x1p15,
        .signed24 => @as(f32, @floatFromInt(std.mem.readInt(i24, bytes[0..3], endian))) / 0x1p23,
        .signed32 => @as(f32, @floatFromInt(std.mem.readInt(i32, bytes[0..4], endian))) / 0x1p31,
        .signed64 => @as(f32, @floatFromInt(std.mem.readInt(i64, bytes[0..8], endian))) / 0x1p63,
        .float32 => @bitCast(std.mem.readInt(u32, bytes[0..4], endian)),
        .float64 => @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, bytes[0..8], endian)))),
    };
}
