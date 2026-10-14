//! WAV/Wave64 packet source: metadata, audio segments, silence, and seeking.
//! riff.zig shares header, chunk, and format parsing across seeking and
//! streaming.
const std = @import("std");
const types = @import("../../types.zig");
const Source = @import("../../Source.zig");
const PacketSource = @import("../../PacketSource.zig");
const riff = @import("riff.zig");
const Stream = riff.Reader(true);
const SeekIndex = @import("../seek_index.zig").Index(SegmentLocation);
const SegmentLocation = struct {
    segment: types.Segment,
    /// Chunk iterator position immediately after this segment.
    next_offset: u64,
    /// Last preceding data frame, or zero before any data. Silence holds its
    /// value.
    previous_frame: u64 = 0,
};
pub const wav = riff.wav;
pub const wave64 = riff.wave64;
const Self = @This();

allocator: std.mem.Allocator,
source: Source,
options: types.Options,
parsed: ?types.ParsedAudio = null,
stream: ?Stream = null,
segments: ?types.AudioData.Iterator = null,
/// Cached wavl segments allocated by init/initParsed. configureInput assigns
/// their frame positions once the codec supplies the encoded bytes per frame.
index: SeekIndex = .{},
metadata: types.Info = undefined,
scheme: ?types.InputScheme = null,
/// Fixed input storage allocated by init/initParsed; packets borrow it.
buffer: []u8 = &.{},
packet_capacity: usize = 0,
current: ?types.Segment = null,
segment_bytes: u64 = 0,
frame: u64 = 0,

/// Recognize a WAVE-family prefix; four bytes suffice for initial dispatch.
/// Full headers are validated while opening or parsing the source.
pub fn probe(prefix: []const u8) bool {
    return wav.probe(prefix) or wave64.probe(prefix);
}

/// Open borrowed WAV/Wave64 input after the dispatcher consumed its four-byte
/// prefix.
/// Allocates source state, fixed input storage, and a bounded index for
/// seekable
/// wavl layouts here. Seekable input uses parsed ranges; sequential input uses
/// Stream.
pub fn init(
    allocator: std.mem.Allocator,
    source: Source,
    prefix: [4]u8,
    options: types.Options,
) types.Error!PacketSource {
    const seekable = source.seek_to != null
        and source.get_size != null
        and try source.getSize() != null;
    const state = try allocator.create(Self);
    state.* = .{ .allocator = allocator, .source = source, .options = options };
    errdefer state.deinit();
    state.buffer = try allocator.alloc(u8, options.bufferCapacity());
    if (seekable) {
        state.parsed = try parse(source);
        state.segments = state.parsed.?.data.iterate(source);
        state.metadata = state.parsed.?.info;
        try state.initIndex();
        return state.interface(state.parsed.?.scheme);
    }
    state.stream = try Stream.initPrefix(allocator, source, options, prefix);
    state.current = try state.stream.?.next();
    const stream = &state.stream.?;
    const fmt = stream.format orelse return error.InvalidData;
    state.metadata = .{
        .format = stream.kind,
        .sample_rate = fmt.sample_rate,
        .channels = fmt.channels,
        .total_frames = if (stream.finished) stream.frames else null,
    };
    return state.interface(fmt.decodingScheme(stream.byte_order));
}

/// Open an unchanged parsed layout with seek and size capabilities.
/// Allocates source state, fixed input storage, and any wavl index here.
pub fn initParsed(
    allocator: std.mem.Allocator,
    source: Source,
    parsed: types.ParsedAudio,
    options: types.Options,
) types.Error!PacketSource {
    if (source.seek_to == null or source.get_size == null) {
        return error.Unseekable;
    }
    const state = try allocator.create(Self);
    state.* = .{
        .allocator = allocator,
        .source = source,
        .options = options,
        .parsed = parsed,
        .metadata = parsed.info,
    };
    errdefer state.deinit();
    state.buffer = try allocator.alloc(u8, options.bufferCapacity());
    state.segments = parsed.data.iterate(state.source);
    try state.initIndex();
    return state.interface(parsed.scheme);
}

fn initIndex(self: *Self) types.Error!void {
    const layout = self.parsed.?.data.layout;
    if (layout != .wavl) return;
    const source = self.source;
    const size = try source.getSize() orelse return error.Unseekable;
    var segments = layout.wavl.iterate(source);
    while (try segments.next()) |segment| {
        if (segment == .data and try segment.data.end() > size) {
            return error.TruncatedData;
        }
        // Empty segments contribute neither samples nor silence history.
        if (
            switch (segment) {
                .data => |range| range.length == 0,
                .silence => |frames| frames == 0,
            }
        )
            continue;
        try self.index.append(
            self.allocator,
            self.options.max_index_bytes,
            .{
                // Assigned during configure, before seeking is available.
                .frame = 0,
                .location = .{
                    .segment = segment,
                    .next_offset = segments.offset,
                },
            },
        );
    }
}

/// Parse WAV/Wave64 metadata and borrowed audio ranges from the start of input.
/// Keep input unchanged while using the result. Position is unspecified on
/// error.
pub const parse = riff.parse;

fn interface(self: *Self, encoding: types.DecodingScheme) PacketSource {
    var format = types.AudioFormat{
        .channels = self.metadata.channels,
        .sample_rate = self.metadata.sample_rate,
    };
    if (self.stream) |stream| {
        if (stream.format.?.extension) |extension| {
            if (
                extension.payload == .extensible
                    and extension.payload.extensible.channel_mask != 0
            ) {
                format.channel_mask = extension.payload.extensible.channel_mask;
            }
        }
    }
    return .{
        .backend = .{ .wave = self },
        .encoding = encoding,
        .format = format,
        .seekable = self.parsed != null,
        .max_payload_bytes = self.options.max_payload_bytes,
    };
}

pub fn configure(self: *Self, scheme: types.InputScheme) types.Error!void {
    if (self.scheme != null) return error.InvalidState;
    const unit = scheme.unitBytes() orelse return error.UnsupportedEncoding;
    if (unit == 0) return error.InvalidData;
    if (unit > self.buffer.len) return error.LimitExceeded;
    self.packet_capacity = self.buffer.len / unit * unit;
    if (self.parsed) |parsed| {
        if (scheme == .samples) {
            var frames: u64 = 0;
            if (parsed.data.layout == .wavl) {
                var previous: u64 = 0;
                for (self.index.entries.items) |*entry| {
                    entry.frame = frames;
                    entry.location.previous_frame = previous;
                    frames = std.math.add(
                        u64,
                        frames,
                        try entry.location.segment.frameCount(unit),
                    )
                        catch return error.InvalidData;
                    if (entry.location.segment == .data) previous = frames - 1;
                }
            } else {
                frames = try parsed.data.frameCount(self.source, unit);
            }
            if (parsed.info.total_frames) |declared| {
                if (frames != declared) return error.InvalidData;
            }
            self.metadata.total_frames = frames;
        }
        self.segments = parsed.data.iterate(self.source);
    }
    self.scheme = scheme;
}

pub fn next(self: *Self) types.Error!PacketSource.Event {
    const scheme = self.scheme orelse return error.InvalidState;
    const unit = scheme.unitBytes().?;
    while (true) {
        if (self.current == null) {
            self.current = if (self.stream) |*stream|
                try stream.next()
            else
                try self.segments.?.next();
            self.segment_bytes = 0;
            if (self.current == null) {
                if (self.stream) |stream| {
                    self.metadata.total_frames = stream.frames;
                }
                return .end;
            }
        }
        switch (self.current.?) {
            .silence => |frames| {
                self.current = null;
                if (frames == 0) continue;
                self.frame = std.math.add(u64, self.frame, frames)
                    catch return error.InvalidData;
                return .{ .silence = frames };
            },
            .data => |range| {
                const remaining = range.length - self.segment_bytes;
                if (remaining == 0) {
                    self.current = null;
                    continue;
                }
                var count: usize = @intCast(
                    @min(remaining, self.packet_capacity),
                );
                if (self.stream) |*stream| {
                    if (stream.kind == .wave64) {
                        // Retain complete final frames plus up to seven padding
                        // bytes.
                        const tail = range.length
                            - (range.length
                                - @min(range.length, @as(u64, unit) + 7))
                                / unit
                                * unit;
                        if (remaining <= tail) {
                            if (remaining > self.options.max_payload_bytes) {
                                return error.LimitExceeded;
                            }
                            if (remaining > self.buffer.len) {
                                return error.LimitExceeded;
                            }
                            try stream.read(
                                self.buffer[0..@intCast(remaining)],
                            );
                            if (try stream.next() != null) {
                                return error.UnsupportedChunkLayout;
                            }
                            const length = try stream.wave64DataLength();
                            if (length < self.segment_bytes) {
                                return error.InvalidData;
                            }
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
                    self.source.reader.readSliceAll(self.buffer[0..count])
                        catch |err| return switch (err) {
                            error.EndOfStream => error.TruncatedData,
                            else => err,
                        };
                }
                if (count % unit != 0) return error.InvalidData;
                self.segment_bytes += count;
                if (self.segment_bytes == range.length) self.current = null;
                if (count == 0) continue;
                var packet = types.Packet{ .bytes = self.buffer[0..count] };
                if (scheme == .samples) {
                    if (self.frame > std.math.maxInt(i64)) {
                        return error.InvalidData;
                    }
                    packet.timestamp = .{
                        .value = @intCast(self.frame),
                        .time_base = .{
                            .numerator = 1,
                            .denominator = self.metadata.sample_rate,
                        },
                    };
                    packet.duration = count / unit;
                    self.frame = std.math.add(u64, self.frame, count / unit)
                        catch return error.InvalidData;
                }
                return .{ .packet = packet };
            },
        }
    }
}

pub fn info(self: *const Self) types.Info {
    return self.metadata;
}

pub fn seek(self: *Self, frame: u64) types.Error!PacketSource.SeekResult {
    const parsed = self.parsed orelse return error.Unseekable;
    const scheme = self.scheme orelse return error.InvalidState;
    if (scheme != .samples) return error.Unseekable;
    if (frame > self.metadata.total_frames.?) return error.OutOfRange;
    self.segments = parsed.data.iterate(self.source);
    self.current = null;
    self.segment_bytes = 0;
    if (frame == self.metadata.total_frames.?) {
        switch (self.segments.?.state) {
            .single => |*segment| segment.* = null,
            .wavl => |*segments| {
                segments.offset = try segments.list.children.end();
            },
        }
        self.frame = frame;
        return .{
            .frame = std.math.cast(i64, frame) orelse return error.InvalidData,
        };
    }
    var anchor = frame;
    var segment_frame: u64 = 0;
    switch (parsed.data.layout) {
        .single => |single| {
            self.segments.?.state.single = null;
            if (single == .silence) anchor = 0;
            self.current = single;
        },
        .wavl => {
            var entry = self.index.atOrBefore(frame)
                orelse return error.InvalidState;
            if (entry.location.segment == .silence) {
                // Replay the preceding data frame so Decoder restores the value
                // held by slnt. Leading silence resumes at frame zero.
                anchor = entry.location.previous_frame;
                entry = self.index.atOrBefore(anchor)
                    orelse return error.InvalidState;
            }
            self.segments.?.state.wavl.offset = entry.location.next_offset;
            segment_frame = entry.frame;
            self.current = entry.location.segment;
        },
    }
    const remaining = anchor - segment_frame;
    switch (self.current.?) {
        .data => |range| {
            self.segment_bytes = remaining * scheme.samples;
            try self.source.seekTo(range.offset + self.segment_bytes);
        },
        .silence => |count| self.current = .{ .silence = count - remaining },
    }
    self.frame = anchor;
    return .{
        .frame = std.math.cast(i64, anchor) orelse return error.InvalidData,
    };
}

pub fn deinit(self: *Self) void {
    if (self.stream) |*stream| stream.deinit();
    self.index.deinit(self.allocator);
    self.allocator.free(self.buffer);
    const allocator = self.allocator;
    allocator.destroy(self);
}
