//! itu-t g.711 a-law and mu-law decoding: one byte per sample into f32.
const std = @import("std");
const types = @import("../types.zig");
const Codec = @import("../Codec.zig");
const Self = @This();

pub const Error = types.Error;
pub const Config = Law;
/// g.711 frames are independent, so a seek needs no earlier frames.
pub const preroll_frames: u64 = 0;

/// the two g.711 companding laws.
pub const Law = enum { alaw, mulaw };

law: Law,
channels: u16,

const tables = [_][256]f32{ table(.alaw), table(.mulaw) };

/// allocate the adapter and sample buffer; a frame is one byte per channel.
pub fn init(
    allocator: std.mem.Allocator,
    law: Config,
    format: types.AudioFormat,
    options: types.Options,
) Error!Codec {
    const unit = Self{ .law = law, .channels = format.channels };
    const adapter = try Codec.UnitAdapter(Self)
        .init(allocator, unit, scheme(format.channels), 1, format, options);
    return adapter.interface(.g711);
}

/// describe complete frames: one byte per channel.
pub fn scheme(channels: u16) types.InputScheme {
    return .{ .samples = channels };
}

/// convert a complete batch; out must have room for every sample.
pub fn decodeUnit(
    self: *Self,
    input: []const u8,
    out: []f32,
) types.Error!usize {
    if (input.len % self.channels != 0) return error.InvalidData;
    if (out.len < input.len) return error.InvalidBufferSize;
    const lookup = &tables[@intFromEnum(self.law)];
    for (out[0..input.len], input) |*sample, code| sample.* = lookup[code];
    return input.len / self.channels;
}

/// g.711 samples carry no decoding history.
pub fn reset(_: *Self) void {}

/// decode every code to its 16-bit linear level, scaled to [-1, 1).
fn table(comptime law: Law) [256]f32 {
    @setEvalBranchQuota(10_000);
    var result: [256]f32 = undefined;
    for (&result, 0..) |*sample, code| {
        const level = switch (law) {
            .alaw => alawLevel(code),
            .mulaw => mulawLevel(code),
        };
        sample.* = @as(f32, @floatFromInt(level)) / 0x1p15;
    }
    return result;
}

fn alawLevel(code: i32) i32 {
    const a = code ^ 0x55;
    const segment: u5 = @intCast((a >> 4) & 7);
    var level = ((a & 0xf) << 4) + 8;
    if (segment != 0) level = (level + 0x100) << (segment - 1);
    return if (a & 0x80 != 0) level else -level;
}

fn mulawLevel(code: i32) i32 {
    const u = ~code & 0xff;
    const segment: u5 = @intCast((u >> 4) & 7);
    const level = ((((u & 0xf) << 3) + 0x84) << segment) - 0x84;
    return if (u & 0x80 != 0) -level else level;
}

const testing = std.testing;

/// ffmpeg's pcm_alaw then pcm_mulaw decoding of every code, 16-bit little
/// endian.
const reference = @embedFile("../testdata/g711_reference.bin");

fn referenceSample(law: Law, code: usize) f32 {
    const offset = (@as(usize, @intFromEnum(law)) * 256 + code) * 2;
    const level = std.mem.readInt(i16, reference[offset..][0..2], .little);
    return @as(f32, @floatFromInt(level)) / 0x1p15;
}

fn allCodes() [256]u8 {
    var codes: [256]u8 = undefined;
    for (&codes, 0..) |*code, index| code.* = @intCast(index);
    return codes;
}

test "all 256 codes of both laws match ffmpeg" {
    const codes = allCodes();
    for ([_]Law{ .alaw, .mulaw }) |law| {
        var out: [256]f32 = undefined;
        var unit: Self = .{ .law = law, .channels = 1 };
        const frames = try unit.decodeUnit(&codes, &out);
        try testing.expectEqual(@as(usize, 256), frames);
        for (out, 0..) |sample, code| {
            try testing.expectEqual(referenceSample(law, code), sample);
        }
    }
}

test "the extreme codes are the standard's" {
    const a = &tables[@intFromEnum(Law.alaw)];
    try testing.expectEqual(@as(f32, 8) / 0x1p15, a[0xd5]);
    try testing.expectEqual(@as(f32, -8) / 0x1p15, a[0x55]);
    try testing.expectEqual(@as(f32, 32256) / 0x1p15, a[0xaa]);
    try testing.expectEqual(@as(f32, -32256) / 0x1p15, a[0x2a]);
    const mu = &tables[@intFromEnum(Law.mulaw)];
    try testing.expectEqual(@as(f32, 0), mu[0xff]);
    try testing.expectEqual(@as(f32, 0), mu[0x7f]);
    try testing.expectEqual(@as(f32, 32124) / 0x1p15, mu[0x80]);
    try testing.expectEqual(@as(f32, -32124) / 0x1p15, mu[0x00]);
}

test "frames are counted per channel and bad sizes are rejected" {
    var unit: Self = .{ .law = .mulaw, .channels = 2 };
    var out: [6]f32 = undefined;
    const frames = try unit.decodeUnit(&.{ 0, 1, 2, 3, 4, 5 }, &out);
    try testing.expectEqual(@as(usize, 3), frames);
    try testing.expectError(
        error.InvalidData,
        unit.decodeUnit(&.{ 0, 1, 2 }, &out),
    );
    try testing.expectError(
        error.InvalidBufferSize,
        unit.decodeUnit(&.{ 0, 1, 2, 3, 4, 5 }, out[0..5]),
    );
}

fn wav(tag: u16, channels: u16, codes: []const u8, out: []u8) []u8 {
    const rate: u32 = 8000;
    const frames: u32 = @intCast(codes.len / channels);
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], @intCast(48 + codes.len), .little);
    @memcpy(out[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], tag, .little);
    std.mem.writeInt(u16, out[22..24], channels, .little);
    std.mem.writeInt(u32, out[24..28], rate, .little);
    std.mem.writeInt(u32, out[28..32], rate * channels, .little);
    std.mem.writeInt(u16, out[32..34], channels, .little);
    std.mem.writeInt(u16, out[34..36], 8, .little);
    @memcpy(out[36..40], "fact");
    std.mem.writeInt(u32, out[40..44], 4, .little);
    std.mem.writeInt(u32, out[44..48], frames, .little);
    @memcpy(out[48..52], "data");
    std.mem.writeInt(u32, out[52..56], @intCast(codes.len), .little);
    @memcpy(out[56..][0..codes.len], codes);
    return out[0..56 + codes.len];
}

const Decoder = @import("../Decoder.zig");
const Source = @import("../Source.zig");

fn decodeFrames(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: types.Options,
) !u64 {
    var reader = std.Io.Reader.fixed(bytes);
    var decoder = try Decoder.initOptions(
        allocator,
        Source.fromFixed(&reader),
        options,
    );
    defer decoder.deinit();
    const channels = decoder.info().channels;
    var out: [64]f32 = undefined;
    var frames: u64 = 0;
    while (true) {
        const got = try decoder.read(out[0..out.len - out.len % channels]);
        if (got == 0) return frames;
        frames += got;
    }
}

fn expectFrames(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    frames: u64,
) !void {
    const got = try decodeFrames(allocator, bytes, .{});
    try testing.expectEqual(frames, got);
}

test "WAV files decode through the Decoder at any channel count" {
    const codes = allCodes()[0..240];
    var file: [56 + 240]u8 = undefined;
    for ([_]Law{ .alaw, .mulaw }) |law| {
        for ([_]u16{ 1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 16 }) |channels| {
            const tag: u16 = if (law == .alaw) 6 else 7;
            const bytes = wav(tag, channels, codes, &file);
            var reader = std.Io.Reader.fixed(bytes);
            var decoder = try Decoder.init(
                testing.allocator,
                Source.fromFixed(&reader),
            );
            defer decoder.deinit();
            const stream = decoder.info();
            try testing.expectEqual(channels, stream.channels);
            try testing.expectEqual(@as(u32, 8000), stream.sample_rate);
            try testing.expectEqual(
                @as(?u64, 240 / channels),
                stream.total_frames,
            );
            var out: [240]f32 = undefined;
            var done: usize = 0;
            while (done < out.len) {
                const want = @min(out.len - done, 3 * @as(usize, channels));
                const got = try decoder.read(out[done..][0..want]);
                try testing.expect(got != 0);
                done += got * channels;
            }
            try testing.expectEqual(@as(usize, 0), try decoder.read(&out));
            for (out, 0..) |sample, code| {
                try testing.expectEqual(referenceSample(law, code), sample);
            }
        }
    }
}

test "every truncation is an error" {
    const codes = allCodes()[0..64];
    var file: [56 + 64]u8 = undefined;
    const bytes = wav(7, 2, codes, &file);
    for (0..bytes.len) |length| {
        if (decodeFrames(testing.allocator, bytes[0..length], .{})) |_| {
            return error.TestUnexpectedResult;
        } else |_| {
        }
    }
}

test "every single bit flip is survivable" {
    const codes = allCodes()[0..64];
    var file: [56 + 64]u8 = undefined;
    const bytes = wav(6, 2, codes, &file);
    for (0..bytes.len * 8) |bit| {
        var damaged: [56 + 64]u8 = undefined;
        @memcpy(&damaged, bytes);
        damaged[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
        if (decodeFrames(testing.allocator, &damaged, .{})) |frames| {
            try testing.expect(frames <= 32);
        } else |_| {
        }
    }
}

test "allocation failures are reported, not leaked" {
    const codes = allCodes()[0..64];
    var file: [56 + 64]u8 = undefined;
    const bytes = wav(6, 2, codes, &file);
    try testing.checkAllAllocationFailures(
        testing.allocator,
        expectFrames,
        .{ bytes, @as(u64, 32) },
    );
}

test "a buffer smaller than one frame is rejected" {
    const codes = allCodes()[0..64];
    var file: [56 + 64]u8 = undefined;
    const bytes = wav(7, 2, codes, &file);
    try testing.expectError(
        error.LimitExceeded,
        decodeFrames(testing.allocator, bytes, .{ .buffer_bytes = 1 }),
    );
    try testing.expectEqual(
        @as(u64, 32),
        try decodeFrames(testing.allocator, bytes, .{ .buffer_bytes = 2 }),
    );
}
