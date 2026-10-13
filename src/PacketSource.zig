//! Encoded packets and container events over borrowed input.
const std = @import("std");
const types = @import("types.zig");
const decoding = @import("decoding.zig");
const Source = @import("Source.zig");
const SeekableReader = @import("SeekableReader.zig");
const parsers = @import("parsers.zig");
const WaveStream = @import("parsers/WaveStream.zig");
const PacketSource = @This();

context: *anyopaque,
vtable: *const VTable,
encoding: types.DecodingScheme,
format: decoding.AudioFormat,
presentation: decoding.Presentation = .{},
/// Decoded position of the first sample, before presentation trimming.
decoded_origin: i64 = 0,
seekable: bool,
max_payload_bytes: usize = 64 * 1024 * 1024,

pub const Event = union(enum) {
    packet: decoding.Packet,
    /// Supply final presentation bounds before emitting the affected packets.
    presentation: decoding.Presentation,
    /// WAVE slnt holds the last decoded frame without advancing codec state.
    silence: u64,
    end,
};

pub const SeekResult = struct { frame: i64 };
pub const VTable = struct {
    configure: *const fn (*anyopaque, decoding.InputScheme) decoding.Error!void,
    next: *const fn (*anyopaque) decoding.Error!Event,
    info: *const fn (*anyopaque) types.Info,
    seek: *const fn (*anyopaque, u64) decoding.Error!SeekResult,
    deinit: *const fn (*anyopaque) void,
};

/// Open existing containers, using sequential parsing when size or seeking is absent.
pub fn init(allocator: std.mem.Allocator, source: Source, options: decoding.Options) decoding.Error!PacketSource {
    const state = try allocator.create(WavePackets);
    state.* = .{ .allocator = allocator, .source = source, .options = options };
    errdefer state.destroy();
    if (source.seek_to != null and source.get_size != null and try source.getSize() != null) {
        state.legacy_vtable = .{ .seekTo = source.seek_to.?, .getSize = source.get_size.? };
        const legacy = state.legacy();
        state.parsed = try parsers.parse(legacy);
        state.segments = state.parsed.?.data.iterate(legacy);
        state.metadata = state.parsed.?.info;
        return state.interface(state.parsed.?.scheme);
    }
    state.stream = try WaveStream.init(allocator, source, options);
    state.current = try state.stream.?.next();
    const stream = &state.stream.?;
    const fmt = stream.format orelse return error.InvalidData;
    state.metadata = .{ .format = stream.kind, .sample_rate = fmt.sample_rate, .channels = fmt.channels, .total_frames = if (stream.finished) stream.frames else null };
    return state.interface(fmt.decodingScheme(stream.byte_order));
}

/// Open an unchanged parsed layout with seek and size capabilities.
pub fn initParsed(allocator: std.mem.Allocator, source: Source, parsed: types.ParsedAudio, options: decoding.Options) decoding.Error!PacketSource {
    if (source.seek_to == null or source.get_size == null) return error.Unseekable;
    const state = try allocator.create(WavePackets);
    state.* = .{
        .allocator = allocator,
        .source = source,
        .options = options,
        .legacy_vtable = .{ .seekTo = source.seek_to.?, .getSize = source.get_size.? },
        .parsed = parsed,
        .metadata = parsed.info,
    };
    state.segments = parsed.data.iterate(state.legacy());
    return state.interface(parsed.scheme);
}

/// Set input framing before requesting packets.
pub fn configure(self: *PacketSource, scheme: decoding.InputScheme) decoding.Error!void {
    try self.vtable.configure(self.context, scheme);
}

/// Borrow the next packet until the next advancing source operation.
pub fn next(self: *PacketSource) decoding.Error!Event {
    const event = try self.vtable.next(self.context);
    if (event == .packet) {
        if (event.packet.bytes.len == 0) return error.InvalidData;
        if (event.packet.bytes.len > self.max_payload_bytes) return error.LimitExceeded;
    }
    return event;
}

/// Return metadata; source frame counts include samples removed by presentation trimming.
pub fn info(self: *const PacketSource) types.Info {
    return self.vtable.info(self.context);
}

/// Seek at or before a decoded frame, retaining enough context for container silence.
pub fn seek(self: *PacketSource, frame: u64) decoding.Error!SeekResult {
    if (!self.seekable) return error.Unseekable;
    return self.vtable.seek(self.context, frame);
}

/// Release packet storage and parser state; borrowed input remains open.
pub fn deinit(self: *PacketSource) void {
    self.vtable.deinit(self.context);
    self.* = undefined;
}

const WavePackets = struct {
    allocator: std.mem.Allocator,
    source: Source,
    options: decoding.Options,
    legacy_vtable: SeekableReader.VTable = undefined,
    parsed: ?types.ParsedAudio = null,
    stream: ?WaveStream = null,
    segments: ?types.AudioData.Iterator = null,
    metadata: types.Info = undefined,
    scheme: ?decoding.InputScheme = null,
    buffer: []u8 = &.{},
    current: ?types.Segment = null,
    segment_bytes: u64 = 0,
    frame: u64 = 0,

    fn legacy(self: *WavePackets) SeekableReader {
        return .{ .reader = self.source.reader, .vtable = &self.legacy_vtable };
    }

    fn interface(self: *WavePackets, encoding: types.DecodingScheme) PacketSource {
        var format = decoding.AudioFormat{ .channels = self.metadata.channels, .sample_rate = self.metadata.sample_rate };
        if (self.stream) |stream| {
            if (stream.format.?.extension) |extension| {
                if (extension.payload == .extensible and extension.payload.extensible.channel_mask != 0) format.channel_mask = extension.payload.extensible.channel_mask;
            }
        }
        return .{
            .context = self,
            .vtable = &.{ .configure = configureInput, .next = nextPacket, .info = getInfo, .seek = seekFrame, .deinit = deinitState },
            .encoding = encoding,
            .format = format,
            .seekable = self.parsed != null,
            .max_payload_bytes = self.options.max_payload_bytes,
        };
    }

    fn configureInput(context: *anyopaque, scheme: decoding.InputScheme) decoding.Error!void {
        const self: *WavePackets = @ptrCast(@alignCast(context));
        if (self.scheme != null) return error.InvalidState;
        const unit = scheme.unitBytes() orelse return error.UnsupportedEncoding;
        if (unit == 0) return error.InvalidData;
        if (unit > self.options.max_payload_bytes) return error.LimitExceeded;
        const capacity = @max(@min(@as(usize, 8192), self.options.max_payload_bytes) / unit, 1) * unit;
        self.buffer = try self.allocator.alloc(u8, capacity);
        if (self.parsed) |parsed| {
            if (scheme == .samples) {
                const frames = try parsed.data.frameCount(self.legacy(), unit);
                if (parsed.info.total_frames) |declared| {
                    if (frames != declared) return error.InvalidData;
                }
                self.metadata.total_frames = frames;
            }
            self.segments = parsed.data.iterate(self.legacy());
        }
        self.scheme = scheme;
    }

    fn nextPacket(context: *anyopaque) decoding.Error!Event {
        const self: *WavePackets = @ptrCast(@alignCast(context));
        const scheme = self.scheme orelse return error.InvalidState;
        const unit = scheme.unitBytes().?;
        while (true) {
            if (self.current == null) {
                self.current = if (self.stream) |*stream| try stream.next() else try self.segments.?.next();
                self.segment_bytes = 0;
                if (self.current == null) {
                    if (self.stream) |stream| self.metadata.total_frames = stream.frames;
                    return .end;
                }
            }
            switch (self.current.?) {
                .silence => |frames| {
                    self.current = null;
                    if (frames == 0) continue;
                    self.frame = std.math.add(u64, self.frame, frames) catch return error.InvalidData;
                    return .{ .silence = frames };
                },
                .data => |range| {
                    const remaining = range.length - self.segment_bytes;
                    if (remaining == 0) {
                        self.current = null;
                        continue;
                    }
                    var count: usize = @intCast(@min(remaining, self.buffer.len));
                    if (self.stream) |*stream| {
                        if (stream.kind == .wave64) {
                            // Retain complete final frames plus up to seven padding bytes.
                            const tail = range.length - (range.length - @min(range.length, @as(u64, unit) + 7)) / unit * unit;
                            if (remaining <= tail) {
                                if (remaining > self.options.max_payload_bytes) return error.LimitExceeded;
                                if (remaining > self.buffer.len) self.buffer = try self.allocator.realloc(self.buffer, @intCast(remaining));
                                try stream.read(self.buffer[0..@intCast(remaining)]);
                                if (try stream.next() != null) return error.UnsupportedChunkLayout;
                                const length = try stream.wave64DataLength();
                                if (length < self.segment_bytes) return error.InvalidData;
                                count = @intCast(length - self.segment_bytes);
                                self.metadata.total_frames = stream.frames;
                                self.current = null;
                            } else {
                                count = @intCast(@min(count, remaining - tail));
                                try stream.read(self.buffer[0..count]);
                            }
                        } else try stream.read(self.buffer[0..count]);
                    } else {
                        try self.source.seekTo(range.offset + self.segment_bytes);
                        self.source.reader.readSliceAll(self.buffer[0..count]) catch |err| return switch (err) {
                            error.EndOfStream => error.TruncatedData,
                            else => err,
                        };
                    }
                    if (count % unit != 0) return error.InvalidData;
                    self.segment_bytes += count;
                    if (self.segment_bytes == range.length) self.current = null;
                    if (count == 0) continue;
                    var packet = decoding.Packet{ .bytes = self.buffer[0..count] };
                    if (scheme == .samples) {
                        if (self.frame > std.math.maxInt(i64)) return error.InvalidData;
                        packet.timestamp = .{ .value = @intCast(self.frame), .time_base = .{ .numerator = 1, .denominator = self.metadata.sample_rate } };
                        packet.duration = count / unit;
                        self.frame = std.math.add(u64, self.frame, count / unit) catch return error.InvalidData;
                    }
                    return .{ .packet = packet };
                },
            }
        }
    }

    fn getInfo(context: *anyopaque) types.Info {
        const self: *WavePackets = @ptrCast(@alignCast(context));
        return self.metadata;
    }

    fn seekFrame(context: *anyopaque, frame: u64) decoding.Error!SeekResult {
        const self: *WavePackets = @ptrCast(@alignCast(context));
        const parsed = self.parsed orelse return error.Unseekable;
        const scheme = self.scheme orelse return error.InvalidState;
        if (scheme != .samples) return error.Unseekable;
        if (frame > self.metadata.total_frames.?) return error.OutOfRange;
        var segments = parsed.data.iterate(self.legacy());
        var position: u64 = 0;
        var previous: u64 = 0;
        var anchor = frame;
        while (try segments.next()) |segment| {
            const frames = try segment.frameCount(scheme.samples);
            if (frame - position < frames) {
                if (segment == .silence) anchor = previous;
                break;
            }
            if (segment == .data and frames != 0) previous = position + frames - 1;
            position += frames;
        }
        self.segments = parsed.data.iterate(self.legacy());
        self.current = null;
        self.segment_bytes = 0;
        self.frame = anchor;
        var remaining = anchor;
        while (try self.segments.?.next()) |segment| {
            const frames = try segment.frameCount(scheme.samples);
            if (remaining < frames) {
                self.current = segment;
                switch (segment) {
                    .data => |range| {
                        self.segment_bytes = remaining * scheme.samples;
                        try self.source.seekTo(range.offset + self.segment_bytes);
                    },
                    .silence => |count| self.current = .{ .silence = count - remaining },
                }
                break;
            }
            remaining -= frames;
        }
        return .{ .frame = std.math.cast(i64, anchor) orelse return error.InvalidData };
    }

    fn deinitState(context: *anyopaque) void {
        const self: *WavePackets = @ptrCast(@alignCast(context));
        self.destroy();
    }

    fn destroy(self: *WavePackets) void {
        if (self.stream) |*stream| stream.deinit();
        self.allocator.free(self.buffer);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};
