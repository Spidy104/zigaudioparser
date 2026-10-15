//! Native FLAC container reader: STREAMINFO, skipped metadata blocks, and one
//! frame per packet; the codec verifies each frame's checksums. Seeking is not
//! supported yet. Frame boundaries are found by scanning for the next valid
//! frame header whose preceding CRC-16 matches, so a frame must fit
//! options.bufferCapacity().
const std = @import("std");
const types = @import("../types.zig");
const Source = @import("../Source.zig");
const PacketSource = @import("../PacketSource.zig");
const flac = @import("../codecs/flac.zig");
const Self = @This();

allocator: std.mem.Allocator,
source: Source,
metadata: types.Info,
/// Fixed storage allocated by init; packets borrow it.
buffer: []u8,
start: usize = 0,
end: usize = 0,
eof: bool = false,
/// First sample number of the next packet.
frame: u64 = 0,

const Frame = struct { len: usize, block_size: u32 };

/// Recognize the fLaC marker; the dispatcher already consumed these four bytes.
pub fn probe(prefix: []const u8) bool {
    return std.mem.eql(u8, prefix, "fLaC");
}

/// Read STREAMINFO and skip all other metadata blocks, leaving the source at
/// the first frame.
/// Allocates source state and the frame buffer here.
pub fn init(
    allocator: std.mem.Allocator,
    source: Source,
    prefix: [4]u8,
    options: types.Options,
) types.Error!PacketSource {
    _ = prefix;
    const reader = source.reader;
    var streaminfo: [34]u8 = undefined;
    var first = true;
    while (true) {
        var head: [4]u8 = undefined;
        try short(reader.readSliceAll(&head));
        const length = std.mem.readInt(u24, head[1..4], .big);
        if (first) {
            if (head[0] & 0x7F != 0 or length != streaminfo.len) {
                return error.InvalidData;
            }
            try short(reader.readSliceAll(&streaminfo));
            first = false;
        } else {
            if (head[0] & 0x7F == 127) return error.InvalidData;
            try short(reader.discardAll(length));
        }
        if (head[0] & 0x80 != 0) break;
    }
    const min_block = std.mem.readInt(u16, streaminfo[0..2], .big);
    const max_block = std.mem.readInt(u16, streaminfo[2..4], .big);
    const fields = std.mem.readInt(u64, streaminfo[10..18], .big);
    const sample_rate: u32 = @intCast(fields >> 44);
    const channels: u16 = @intCast((fields >> 41 & 7) + 1);
    const bits: u8 = @intCast((fields >> 36 & 31) + 1);
    const total = fields & (1 << 36) - 1;
    if (min_block < flac.min_block or max_block < min_block) {
        return error.InvalidData;
    }
    if (options.bufferCapacity() < 32) return error.LimitExceeded;
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    const buffer = try allocator.alloc(u8, options.bufferCapacity());
    self.* = .{
        .allocator = allocator,
        .source = source,
        .buffer = buffer,
        .metadata = .{
            .format = .flac,
            .sample_rate = sample_rate,
            .channels = channels,
            .total_frames = if (total == 0) null else total,
        },
    };
    return .{
        .backend = .{ .flac = self },
        .encoding = .{ .flac = .{ .max_block = max_block, .bits = bits } },
        .format = .{ .sample_rate = sample_rate, .channels = channels },
        .seekable = false,
        .max_payload_bytes = options.max_payload_bytes,
    };
}

/// Frames are delimited here, so only packet framing is meaningful.
pub fn configure(_: *Self, scheme: types.InputScheme) types.Error!void {
    if (scheme != .packets) return error.UnsupportedEncoding;
}

/// Borrow the next complete frame until the next call; end follows the last
/// frame. Input that does not end on a valid frame returns InvalidData.
pub fn next(self: *Self) types.Error!PacketSource.Event {
    while (true) {
        const data = self.buffer[self.start..self.end];
        if (data.len == 0 and self.eof) return .end;
        if (data.len != 0) {
            if (try self.frameAt(data)) |frame| {
                const timestamp = std.math.cast(i64, self.frame)
                    orelse return error.InvalidData;
                self.frame = std.math.add(u64, self.frame, frame.block_size)
                    catch return error.InvalidData;
                self.start += frame.len;
                return .{
                    .packet = .{
                        .bytes = data[0..frame.len],
                        .timestamp = .{
                            .value = timestamp,
                            .time_base = .{
                                .numerator = 1,
                                .denominator = self.metadata.sample_rate,
                            },
                        },
                        .duration = frame.block_size,
                    },
                };
            }
        }
        try self.refill();
    }
}

/// Measure the frame starting data, or return null when more input is needed.
/// A frame ends where the next valid header follows its CRC-16; the final
/// frame runs to the end of the input and the codec validates it.
fn frameAt(self: *const Self, data: []const u8) types.Error!?Frame {
    const header = flac.parseHeader(data)
        catch |err| switch (err) {
            error.TruncatedData => if (self.eof) return err else return null,
            error.InvalidData => return err,
        };
    // One running CRC over the bytes before each candidate keeps this linear
    // in the buffer size however many false sync codes it holds.
    var crc: u16 = 0;
    var done: usize = 0;
    var at = header.len + 3;
    while (std.mem.findScalarPos(u8, data, at, 0xFF)) |sync| : (at = sync + 1) {
        _ = flac.parseHeader(data[sync..])
            catch |err| switch (err) {
                error.TruncatedData => if (self.eof) continue else return null,
                error.InvalidData => continue,
            };
        crc = flac.crc16(crc, data[done..sync - 2]);
        done = sync - 2;
        if (crc == std.mem.readInt(u16, data[done..][0..2], .big)) {
            return .{ .len = sync, .block_size = header.block_size };
        }
    }
    if (!self.eof) return null;
    return .{ .len = data.len, .block_size = header.block_size };
}

fn refill(self: *Self) types.Error!void {
    if (self.start != 0) {
        @memmove(
            self.buffer[0..self.end - self.start],
            self.buffer[self.start..self.end],
        );
        self.end -= self.start;
        self.start = 0;
    }
    if (self.end == self.buffer.len) return error.LimitExceeded;
    self.end += try self.source.reader.readSliceShort(self.buffer[self.end..]);
    if (self.end < self.buffer.len) self.eof = true;
}

/// total_frames is null when STREAMINFO does not record the sample count.
pub fn info(self: *const Self) types.Info {
    return self.metadata;
}

/// Seeking is not supported yet.
pub fn seek(_: *Self, _: u64) types.Error!PacketSource.SeekResult {
    return error.Unseekable;
}

/// Release the frame buffer and state.
pub fn deinit(self: *Self) void {
    const allocator = self.allocator;
    allocator.free(self.buffer);
    allocator.destroy(self);
}

/// Report input that ends early as TruncatedData.
fn short(
    result: anytype,
) types.Error!@typeInfo(@TypeOf(result)).error_union.payload {
    return result
        catch |err| switch (err) {
            error.EndOfStream => error.TruncatedData,
            else => |other| other,
        };
}

const testing = std.testing;
const Decoder = @import("../Decoder.zig");
const Md5 = std.crypto.hash.Md5;

/// ffmpeg-encoded: LPC, fixed predictors, mid/side, 24-bit mono, verbatim.
/// Each carries the MD5 of its decoded samples in STREAMINFO.
const fixtures = [_][]const u8{
    @embedFile("../testdata/stereo_lpc.flac"),
    @embedFile("../testdata/stereo_fixed.flac"),
    @embedFile("../testdata/stereo_mid_side.flac"),
    @embedFile("../testdata/mono_24bit.flac"),
    @embedFile("../testdata/noise_verbatim.flac"),
};

/// Fixtures keep STREAMINFO at byte 8: total samples, bit depth and the MD5
/// of the decoded integers live there.
fn streamInfoFields(file: []const u8) u64 {
    return std.mem.readInt(u64, file[18..26], .big);
}

/// Decode a whole file, hashing the reconstructed integers like STREAMINFO
/// does, and return the frame count.
fn decodeAll(
    allocator: std.mem.Allocator,
    file: []const u8,
    options: types.Options,
    chunk: usize,
    seekable: bool,
    digest: *[16]u8,
) !u64 {
    var reader = std.Io.Reader.fixed(file);
    const source = if (seekable)
        Source.fromFixed(&reader)
    else
        Source.fromReader(&reader);
    var decoder = try Decoder.initOptions(allocator, source, options);
    defer decoder.deinit();
    const channels = decoder.info().channels;
    const depth: u5 = @intCast(streamInfoFields(file) >> 36 & 31);
    const scale: f32 = @floatFromInt(@as(u32, 1) << depth);
    const out = try allocator.alloc(f32, chunk * channels);
    defer allocator.free(out);
    var md5 = Md5.init(.{});
    var frames: u64 = 0;
    while (true) {
        const count = try decoder.read(out);
        if (count == 0) break;
        frames += count;
        for (out[0..count * channels]) |sample| {
            const value: i32 = @intFromFloat(sample * scale);
            var word: [4]u8 = undefined;
            std.mem.writeInt(i32, &word, value, .little);
            md5.update(word[0..(@as(usize, depth) + 8) / 8]);
        }
    }
    md5.final(digest);
    try testing.expectEqual(frames, decoder.info().total_frames.?);
    return frames;
}

fn expectExact(
    allocator: std.mem.Allocator,
    file: []const u8,
    options: types.Options,
    chunk: usize,
    seekable: bool,
) !void {
    var digest: [16]u8 = undefined;
    const frames = try decodeAll(
        allocator,
        file,
        options,
        chunk,
        seekable,
        &digest,
    );
    try testing.expectEqualSlices(u8, file[26..42], &digest);
    try testing.expectEqual(streamInfoFields(file) & (1 << 36) - 1, frames);
}

fn decodeBytes(file: []const u8, options: types.Options) !u64 {
    var digest: [16]u8 = undefined;
    return decodeAll(testing.allocator, file, options, 64, true, &digest);
}

test "fixtures decode to their STREAMINFO MD5 at any read size" {
    for (fixtures) |fixture| {
        for ([_]usize{ 1, 7, 4096 }) |chunk| {
            for ([_]usize{ 4096, 64 * 1024 }) |buffer| {
                for ([_]bool{ true, false }) |seekable| {
                    try expectExact(
                        testing.allocator,
                        fixture,
                        .{ .buffer_bytes = buffer },
                        chunk,
                        seekable,
                    );
                }
            }
        }
    }
}

test "stream information" {
    var reader = std.Io.Reader.fixed(fixtures[0]);
    const source = Source.fromFixed(&reader);
    var decoder = try Decoder.init(testing.allocator, source);
    defer decoder.deinit();
    const stream = decoder.info();
    try testing.expectEqual(types.Format.flac, stream.format);
    try testing.expectEqual(@as(u32, 44100), stream.sample_rate);
    try testing.expectEqual(@as(u16, 2), stream.channels);
    try testing.expectEqual(@as(?u64, 1764), stream.total_frames);
}

test "frames larger than the buffer are rejected" {
    const file = fixtures[0];
    const small = types.Options{ .buffer_bytes = 64 };
    try testing.expectError(error.LimitExceeded, decodeBytes(file, small));
    const tiny = types.Options{ .buffer_bytes = 16 };
    try testing.expectError(error.LimitExceeded, decodeBytes(file, tiny));
}

test "allocation failures are reported, not leaked" {
    for ([_]usize{ 0, 3 }) |which| {
        try testing.checkAllAllocationFailures(
            testing.allocator,
            expectExact,
            .{ fixtures[which], types.Options{}, @as(usize, 7), true },
        );
    }
}

test "decoding allocates nothing after init and deinit frees everything" {
    for (fixtures) |fixture| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var reader = std.Io.Reader.fixed(fixture);
        const source = Source.fromFixed(&reader);
        var decoder = try Decoder.init(failing.allocator(), source);
        const allocations = failing.allocations;
        const bytes = failing.allocated_bytes;
        var out: [8 * 100]f32 = undefined;
        const channels = decoder.info().channels;
        while (try decoder.read(out[0..100 * channels]) != 0) {}
        try testing.expectEqual(allocations, failing.allocations);
        try testing.expectEqual(bytes, failing.allocated_bytes);
        decoder.deinit();
        try testing.expectEqual(failing.allocations, failing.deallocations);
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "every truncation is an error" {
    for ([_]usize{ 0, 3 }) |which| {
        const file = fixtures[which];
        for (0..file.len) |length| {
            if (decodeBytes(file[0..length], .{})) |_| {
                return error.TestUnexpectedResult;
            } else |_| {
            }
        }
    }
}

test "every single bit flip is survivable" {
    var copy: [4096]u8 = undefined;
    for ([_]usize{ 0, 3, 4 }) |which| {
        const file = fixtures[which];
        for (0..file.len) |index| {
            for (0..8) |bit| {
                @memcpy(copy[0..file.len], file);
                copy[index] ^= @as(u8, 1) << @intCast(bit);
                _ = decodeBytes(copy[0..file.len], .{}) catch {};
            }
        }
    }
}

test "a header-like byte pattern inside a frame is not a frame boundary" {
    var copy: [1024]u8 = undefined;
    const data = copy[0..fixtures[4].len];
    @memcpy(data, fixtures[4]);
    var start: usize = 4;
    while (true) {
        const last = data[start] & 0x80 != 0;
        start += 4 + std.mem.readInt(u24, data[start + 1..][0..3], .big);
        if (last) break;
    }
    const header = try flac.parseHeader(data[start..]);
    var end = start + header.len + 3;
    while (true) : (end += 1) {
        if (data[end] != 0xFF) continue;
        _ = flac.parseHeader(data[end..]) catch continue;
        const stored = std.mem.readInt(u16, data[end - 2..][0..2], .big);
        if (flac.crc16(0, data[start..end - 2]) == stored) break;
    }
    const inside = start + header.len + 20;
    @memcpy(data[inside..][0..header.len], data[start..][0..header.len]);
    std.mem.writeInt(
        u16,
        data[end - 2..][0..2],
        flac.crc16(0, data[start..end - 2]),
        .big,
    );
    try testing.expect(inside + header.len < end - 2);
    _ = try decodeBytes(data, .{});
}
test "malformed metadata" {
    const original = fixtures[0];
    var copy: [4096]u8 = undefined;
    const fields = streamInfoFields(original);
    const cases = [_]struct { anyerror, usize, u64 }{
        .{ error.InvalidData, 4, 1 },
        .{ error.InvalidData, 42, 127 },
        .{ error.InvalidData, 8, 0 },
        .{ error.InvalidData, 8, 255 },
        .{ error.UnsupportedEncoding, 0, fields | 31 << 36 },
        .{ error.InvalidData, 0, fields & ~(@as(u64, 31) << 36) },
        .{ error.InvalidData, 0, fields & ~(@as(u64, 0xFFFFF) << 44) },
        .{ error.TruncatedData, 0, fields + 1 },
        .{ error.InvalidData, 0, fields - 1 },
    };
    for (cases) |case| {
        @memcpy(copy[0..original.len], original);
        if (case[1] == 0) {
            std.mem.writeInt(u64, copy[18..26], case[2], .big);
        } else {
            copy[case[1]] = @intCast(case[2]);
            if (case[1] == 8) copy[9] = 0;
        }
        const result = decodeBytes(copy[0..original.len], .{});
        try testing.expectError(case[0], result);
    }
    try testing.expectError(
        error.TruncatedData,
        decodeBytes(original[0..20], .{}),
    );
    try testing.expectError(
        error.UnsupportedFormat,
        decodeBytes("ID3\x03", .{}),
    );
}
