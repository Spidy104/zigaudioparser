//! User-facing read/seek pipeline: container packets, codec output, and
//! trimming.
//! Returns interleaved f32 samples in source channel order.
//! Integer PCM is normalized to [-1, 1]; floating-point samples retain their
//! scale.
const std = @import("std");
const types = @import("types.zig");
const Source = @import("Source.zig");
const PacketSource = @import("PacketSource.zig");
const Codec = @import("Codec.zig");
const Decoder = @This();

pub const Error = types.DecoderError;
pub const Options = types.Options;

allocator: std.mem.Allocator,
packets: PacketSource,
codec: Codec,
metadata: types.Info,
format: types.AudioFormat,
presentation: types.Presentation,
/// Fixed history storage allocated at initialization. Only format.channels
/// samples are active; retained for WAVE slnt events (repeat the previous
/// frame).
last_frame: []f32,
/// Borrows unread codec output; read copies it to the caller's output slice.
pending: []const f32 = &.{},
deferred_block: ?types.AudioBlock = null,
silence: u64 = 0,
decoded_frame: i128 = 0,
discard_until: ?u64 = null,
frame_offset: u64 = 0,
draining: bool = false,
finished: bool = false,
format_notice: bool = false,
pending_format: ?types.AudioFormat = null,
failure: ?Error = null,

/// Open audio, borrowing exclusive source access until deinit.
/// Keep the source reader and buffer in place and input open and unchanged.
/// Allocates pipeline state and buffers during initialization.
/// deinit releases all owned storage.
pub fn init(allocator: std.mem.Allocator, source: Source) Error!Decoder {
    return initOptions(allocator, source, .{});
}

/// Open audio with explicit buffer capacities and input/index limits.
pub fn initOptions(
    allocator: std.mem.Allocator,
    source: Source,
    options: Options,
) Error!Decoder {
    return initPackets(
        allocator,
        try PacketSource.init(allocator, source, options),
        options,
    );
}

/// Open parsed WAV/Wave64 audio using the same unchanged, seekable source.
pub fn initParsed(
    allocator: std.mem.Allocator,
    source: Source,
    parsed: types.ParsedAudio,
) Error!Decoder {
    return initPackets(
        allocator,
        try PacketSource.initParsed(allocator, source, parsed, .{}),
        .{},
    );
}

/// Take ownership of a packet source, including on initialization failure.
/// Initialize its built-in codec and reserve last-frame history for at least
/// options.reserve_channels channels.
pub fn initPackets(
    allocator: std.mem.Allocator,
    source: PacketSource,
    options: Options,
) Error!Decoder {
    var packets = source;
    var codec = Codec.init(
        allocator,
        packets.encoding,
        packets.format,
        options,
    ) catch |err| {
        packets.deinit();
        return err;
    };
    packets.configure(codec.scheme) catch |err| {
        codec.deinit();
        packets.deinit();
        return err;
    };
    var result = Decoder{
        .allocator = allocator,
        .packets = packets,
        .codec = codec,
        .metadata = packets.info(),
        .format = packets.format,
        .presentation = packets.presentation,
        .decoded_frame = packets.decoded_origin,
        .last_frame = &.{},
    };
    errdefer result.deinit();
    result.last_frame = try allocator.alloc(
        f32,
        @max(result.format.channels, options.reserve_channels),
    );
    @memset(result.last_frame, 0);
    if (result.format.channels == 0 or result.format.sample_rate == 0) {
        while (result.format.channels == 0 or result.format.sample_rate == 0) {
            switch (try result.advance()) {
                .finished => return error.InvalidData,
                .format_changed => try result.applyFormat(),
                .ready => {},
            }
        }
    }
    if (result.presentation.end) |end| {
        if (end < result.presentation.start) return error.InvalidData;
        result.metadata.total_frames = end - result.presentation.start;
    } else if (packets.info().total_frames) |count| {
        const end = @as(i128, packets.decoded_origin) + count;
        if (end < result.presentation.start) return error.InvalidData;
        result.metadata.total_frames = std.math.cast(
            u64,
            end - result.presentation.start,
        )
            orelse return error.InvalidData;
    }
    return result;
}

/// Release owned buffers and codec state; borrowed input remains open.
pub fn deinit(self: *Decoder) void {
    self.codec.deinit();
    self.packets.deinit();
    self.allocator.free(self.last_frame);
    self.* = undefined;
}

/// Return the current output format and known presented frame count.
pub fn info(self: *const Decoder) types.Info {
    return self.metadata;
}

/// Return frames written, leaving the unused tail untouched; zero means EOF.
/// out must be nonempty and channel-aligned. After FormatChanged, consult info
/// and retry.
/// After an input error, discard output and seek successfully or reopen before
/// reading.
pub fn read(self: *Decoder, out: []f32) Error!usize {
    if (self.failure) |err| return err;
    if (self.format_notice) {
        self.format_notice = false;
        self.applyFormat() catch |err| {
            self.failure = err;
            return err;
        };
        return error.FormatChanged;
    }
    if (out.len == 0 or out.len % self.format.channels != 0) {
        return error.InvalidBufferSize;
    }
    const count = self.readFrames(out) catch |err| {
        if (err != error.FormatChanged) self.failure = err;
        return err;
    };
    self.frame_offset = std.math.add(u64, self.frame_offset, count) catch {
        self.failure = error.InvalidData;
        return error.InvalidData;
    };
    return count;
}

fn readFrames(self: *Decoder, out: []f32) Error!usize {
    const channels = self.format.channels;
    var written: usize = 0;
    while (written < out.len) {
        if (self.pending.len != 0) {
            const count = @min(out.len - written, self.pending.len);
            @memcpy(out[written..][0..count], self.pending[0..count]);
            self.pending = self.pending[count..];
            written += count;
        } else if (self.silence != 0) {
            const frames: usize = @intCast(
                @min((out.len - written) / channels, self.silence),
            );
            for (0..frames) |frame_index| {
                @memcpy(
                    out[written + frame_index * channels..][0..channels],
                    self.last_frame[0..channels],
                );
            }
            written += frames * channels;
            self.silence -= frames;
        } else {
            switch (try self.advance()) {
                .ready => {},
                .finished => break,
                .format_changed => {
                    if (written != 0) {
                        self.format_notice = true;
                        break;
                    }
                    try self.applyFormat();
                    return error.FormatChanged;
                },
            }
        }
    }
    return written / channels;
}

const Advance = enum { ready, finished, format_changed };

fn advance(self: *Decoder) Error!Advance {
    if (self.finished) return .finished;
    if (self.deferred_block) |block| {
        self.deferred_block = null;
        try self.acceptBlock(block);
        return .ready;
    }
    // A codec must request input, emit output, or finish without unbounded
    // empty events.
    var empty_events: usize = 0;
    while (true) {
        const result = try self.codec.receive();
        switch (result) {
            .audio => |block| {
                if (!self.format.eql(block.format)) {
                    self.pending_format = block.format;
                    self.deferred_block = block;
                    return .format_changed;
                }
                if (block.samples.len == 0) {
                    empty_events += 1;
                    if (empty_events > 1) return error.InvalidState;
                    continue;
                }
                try self.acceptBlock(block);
                if (self.pending.len != 0) return .ready;
            },
            .format_changed => |format| {
                if (self.format.eql(format)) return error.InvalidState;
                self.pending_format = format;
                return .format_changed;
            },
            .finished => {
                if (!self.draining) return error.InvalidState;
                self.finished = true;
                const total = self.decoded_frame;
                if (self.packets.info().total_frames) |expected| {
                    const count = total - self.packets.decoded_origin;
                    if (count < expected) return error.TruncatedData;
                    if (count > expected) return error.InvalidData;
                }
                if (total < self.presentation.start) return error.TruncatedData;
                if (self.presentation.end) |end| {
                    if (total < end) return error.TruncatedData;
                }
                const end: u64 = @intCast(
                    @min(
                        total,
                        self.presentation.end orelse std.math.maxInt(u64),
                    ),
                );
                self.metadata.total_frames = end - self.presentation.start;
                return .finished;
            },
            .need_input => {
                if (self.draining) return error.InvalidState;
                const event = try self.packets.next();
                switch (event) {
                    .packet => |packet| {
                        // receive just requested input; refusing it would
                        // deadlock the loop.
                        if (try self.codec.submit(packet) != .accepted) {
                            return error.InvalidState;
                        }
                        empty_events = 0;
                    },
                    .presentation => |bounds| {
                        if (bounds.start != self.presentation.start) {
                            return error.InvalidData;
                        }
                        if (self.presentation.end) |end| {
                            if (bounds.end == null or bounds.end.? != end) {
                                return error.InvalidData;
                            }
                        }
                        if (bounds.end) |end| {
                            if (
                                end < bounds.start
                                    or end < self.decoded_frame
                            ) {
                                return error.InvalidData;
                            }
                            self.metadata.total_frames = end - bounds.start;
                        }
                        self.presentation = bounds;
                    },
                    .silence => |frames| {
                        const start = self.decoded_frame;
                        self.decoded_frame = std.math.add(i128, start, frames)
                            catch return error.InvalidData;
                        const first = @max(
                            start,
                            @max(
                                self.presentation.start,
                                self.discard_until orelse 0,
                            ),
                        );
                        const last = @min(
                            self.decoded_frame,
                            self.presentation.end orelse std.math.maxInt(u64),
                        );
                        self.silence = @intCast(@max(0, last - first));
                        if (self.silence != 0) return .ready;
                    },
                    .end => {
                        try self.codec.finish();
                        self.draining = true;
                    },
                }
            },
        }
    }
}

fn applyFormat(self: *Decoder) Error!void {
    const format = self.pending_format orelse return error.InvalidState;
    if (format.channels == 0 or format.sample_rate == 0) {
        return error.InvalidData;
    }
    if (format.channels > self.last_frame.len) return error.LimitExceeded;
    @memset(self.last_frame, 0);
    if (
        self.format.sample_rate != 0
            and self.format.sample_rate != format.sample_rate
    ) {
        self.metadata.variable_sample_rate = true;
    }
    self.format = format;
    self.pending_format = null;
    self.metadata.channels = format.channels;
    self.metadata.sample_rate = format.sample_rate;
    self.metadata.total_frames = null;
}

fn acceptBlock(self: *Decoder, block: types.AudioBlock) Error!void {
    const channels = block.format.channels;
    if (channels == 0 or block.samples.len % channels != 0) {
        return error.InvalidState;
    }
    const start = self.decoded_frame;
    if (block.timestamp) |timestamp| {
        if (
            timestamp.time_base.denominator == 0
                or timestamp.time_base.numerator == 0
        ) {
            return error.InvalidData;
        }
    }
    const frames = block.frameCount();
    self.decoded_frame = std.math.add(i128, start, frames)
        catch return error.InvalidData;
    if (frames != 0) {
        @memcpy(
            self.last_frame[0..channels],
            block.samples[block.samples.len - channels..],
        );
    }
    const first = @max(
        start,
        @max(self.presentation.start, self.discard_until orelse 0),
    );
    const last = @min(
        self.decoded_frame,
        self.presentation.end orelse std.math.maxInt(u64),
    );
    if (last > first) {
        const offset: usize = @intCast(first - start);
        const count: usize = @intCast(last - first);
        self.pending = block.samples[offset * channels..][0..count * channels];
    }
}

/// Seek to an absolute presented frame; successful seeking clears prior input
/// errors.
/// Sequential input returns Unseekable without changing decoder state.
pub fn seekFrame(self: *Decoder, frame: u64) Error!void {
    if (!self.packets.seekable) return error.Unseekable;
    if (self.metadata.total_frames) |total| {
        if (frame > total) return error.OutOfRange;
    }
    self.seekInternal(frame) catch |err| {
        self.failure = err;
        return err;
    };
    self.frame_offset = frame;
    self.failure = null;
}

fn seekInternal(self: *Decoder, frame: u64) Error!void {
    const target = std.math.add(u64, self.presentation.start, frame)
        catch return error.OutOfRange;
    const anchor = try self.packets.seek(target -| self.codec.preroll_frames);
    if (@as(i128, anchor.frame) > target) return error.InvalidState;
    self.codec.reset();
    self.pending = &.{};
    self.deferred_block = null;
    self.silence = 0;
    self.decoded_frame = anchor.frame;
    self.draining = false;
    self.finished = false;
    self.format_notice = false;
    self.pending_format = null;
    @memset(self.last_frame, 0);
    self.discard_until = target;
    defer self.discard_until = null;
    while (self.decoded_frame < target) {
        switch (try self.advance()) {
            .ready => {},
            .finished => {
                if (self.decoded_frame < target) return error.OutOfRange;
            },
            .format_changed => try self.applyFormat(),
        }
    }
}

/// Return presented frame position after the last successful read or seek.
pub fn tellFrame(self: *const Decoder) u64 {
    return self.frame_offset;
}
