//! Container-independent PCM conversion into interleaved f32 samples.
const std = @import("std");
const types = @import("../types.zig");

format: types.PcmFormat,
channels: u16,

/// Describe complete PCM frames after validating the sample format.
pub fn scheme(
    format: types.PcmFormat,
    channels: u16,
) types.Error!types.InputScheme {
    if (channels == 0) return error.InvalidData;
    try validateFormat(format);
    return .{
        .samples = @as(u32, channels)
            * @as(u32, @intCast(format.sample_type.byteSize())),
    };
}

/// Convert a complete batch; out must have room for every sample.
pub fn decodeUnit(
    self: *@This(),
    input: []const u8,
    out: []f32,
) types.Error!usize {
    const size = self.format.sample_type.byteSize();
    if (input.len % (size * self.channels) != 0) return error.InvalidData;
    const samples = input.len / size;
    if (out.len < samples) return error.InvalidBufferSize;
    for (out[0..samples], 0..) |*sample, sample_index| {
        sample.* = decodeSample(
            input[sample_index * size..][0..size],
            self.format,
        );
    }
    return samples / self.channels;
}

/// PCM samples carry no decoding history.
pub fn reset(_: *@This()) void {}

/// Return InvalidData if valid_bits is zero or exceeds the sample storage
/// width.
pub fn validateFormat(format: types.PcmFormat) types.ValidationError!void {
    if (format.valid_bits) |valid_bits| {
        if (valid_bits == 0 or valid_bits > format.sample_type.byteSize() * 8) {
            return error.InvalidData;
        }
    }
}

/// Convert one encoded sample to f32; bytes must contain a full sample.
fn decodeSample(bytes: []const u8, format: types.PcmFormat) f32 {
    const endian = format.byte_order;
    return switch (format.sample_type) {
        .unsigned8 => (@as(f32, @floatFromInt(bytes[0])) - 128.0) / 128.0,
        .signed8 => @as(f32, @floatFromInt(@as(i8, @bitCast(bytes[0]))))
            / 0x1p7,
        .signed16 => @as(
            f32,
            @floatFromInt(std.mem.readInt(i16, bytes[0..2], endian)),
        )
            / 0x1p15,
        .signed24 => @as(
            f32,
            @floatFromInt(std.mem.readInt(i24, bytes[0..3], endian)),
        )
            / 0x1p23,
        .signed32 => @as(
            f32,
            @floatFromInt(std.mem.readInt(i32, bytes[0..4], endian)),
        )
            / 0x1p31,
        .signed64 => @as(
            f32,
            @floatFromInt(std.mem.readInt(i64, bytes[0..8], endian)),
        )
            / 0x1p63,
        .float32 => @bitCast(std.mem.readInt(u32, bytes[0..4], endian)),
        .float64 => @floatCast(
            @as(f64, @bitCast(std.mem.readInt(u64, bytes[0..8], endian))),
        ),
    };
}
