//! libopus multistream decoder
const std = @import("std");
const Codec = @import("../Codec.zig");
const types = @import("../types.zig");
const Config = @import("../types.zig").OpusConfig;
const libopus = @cImport({
        @cInclude("opus_multistream.h");
    });
const Self = @This();
allocator: std.mem.Allocator,
/// Opaque C state allocated through the caller's allocator during
/// initialization.
/// Its address remains stable until deinit.
/// Use 16-byte alignment for the C decoder state, including its internal
/// arrays.
storage: []align(16) u8,
config: Config,
format: types.AudioFormat,

// RFC 7845 recommends at least 80 ms. Longer history also converges CELT's
// inter-frame energy prediction on files that retain differences after that
// minimum, without replaying the stream from its beginning.
pub const preroll_frames = 24000; // 500 ms at 48 kHz.

/// Create an owning adapter for 48 kHz output in source channel order.
/// Copy configuration and allocate libopus state
/// UnitAdapter also allocates state and 5760 * channels f32 output samples
/// here.
/// Decoding uses libopus's internal stack scratch (VAR_ARRAYS)
pub fn init(
    allocator: std.mem.Allocator,
    config: Config,
    format: types.AudioFormat,
    options: types.Options,
) types.Error!*Codec.UnitAdapter(Self) {
    if (
        format.sample_rate != 48000
            or format.channels > 8
            or config.streams == 0
            or config.coupled_streams > config.streams
    ) {
        return error.InvalidData;
    }
    const state_bytes = libopus.opus_multistream_decoder_get_size(
        config.streams,
        config.coupled_streams,
    );
    if (state_bytes <= 0) return error.InvalidData;
    const storage = try allocator.alignedAlloc(
        u8,
        .@"16",
        @intCast(state_bytes),
    );
    errdefer allocator.free(storage);
    var unit = Self{
        .allocator = allocator,
        .storage = storage,
        .config = config,
        .format = format,
    };
    if (
        libopus.opus_multistream_decoder_init(
            unit.state(),
            48000,
            format.channels,
            config.streams,
            config.coupled_streams,
            &config.mapping,
        ) != libopus.OPUS_OK
    ) {
        return error.InvalidData;
    }
    // 5760 = maximum 120 ms packet duration at 48 kHz, per channel.
    return Codec.UnitAdapter(Self)
        .init(allocator, unit, .packets, 5760, format, options);
}
/// Borrow the opaque decoder within the aligned allocation.
fn state(self: *Self) *libopus.OpusMSDecoder {
    return @ptrCast(self.storage.ptr);
}
/// Reinitialize decoding history with the same channels and mapping.
pub fn reset(self: *Self) void {
    const result = libopus.opus_multistream_decoder_init(
        self.state(),
        48000,
        self.format.channels,
        self.config.streams,
        self.config.coupled_streams,
        &self.config.mapping,
    );
    std.debug.assert(result == libopus.OPUS_OK);
}
/// Release C decoder state; UnitAdapter releases its separate PCM output
/// storage.
pub fn deinit(self: *Self) void {
    self.allocator.free(self.storage);
}
/// Decode one multistream packet and apply header gain; return samples per
/// channel.
/// out must hold 5760 * format.channels samples. No resampling, clipping,
/// optional
/// tag gain, or packet-loss concealment is applied; Decoder handles sample
/// trimming.
pub fn decodeUnit(
    self: *Self,
    bytes: []const u8,
    out: []f32,
) types.Error!usize {
    const packet_length = std.math.cast(c_int, bytes.len)
        orelse return error.LimitExceeded;
    // The final zero disables forward error correction: decode this packet
    // itself.
    const decoded_samples = libopus.opus_multistream_decode_float(
        self.state(),
        bytes.ptr,
        packet_length,
        out.ptr,
        5760,
        0,
    );
    if (decoded_samples < 0) return error.InvalidData;
    const sample_count: usize = @intCast(decoded_samples);
    // Eight fractional bits mean 256 stored units per dB.
    // Convert signed Q7.8 dB to a linear amplitude multiplier: 10^(dB/20).
    const gain = std.math.pow(
        f32,
        10,
        @as(f32, @floatFromInt(self.config.gain_q8)) / (20 * 256),
    );
    for (out[0..sample_count * self.format.channels]) |*sample| {
        sample.* *= gain;
    }
    return sample_count;
}
