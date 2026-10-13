//! Packet framing, audio blocks, and decoder lifecycle contracts.
const types = @import("types.zig");

pub const Error = types.DecoderError;

pub const Options = struct {
    /// Maximum bytes retained for one packet or configuration payload.
    max_payload_bytes: usize = 64 * 1024 * 1024,
};

pub const InputScheme = union(enum) {
    samples: u32,
    blocks: u32,
    packets,
    parsed,

    /// Return bytes per complete input unit, or null for packet framing.
    pub fn unitBytes(self: InputScheme) ?u32 {
        return switch (self) {
            .samples, .blocks => |size| size,
            .packets, .parsed => null,
        };
    }
};

pub const TimeBase = struct { numerator: u32, denominator: u32 };
/// Media time; packet sources map timestamps to frame positions for seeking.
pub const Timestamp = struct { value: i64, time_base: TimeBase };

/// Decoded frame interval to present, in sample sequence order.
pub const Presentation = struct { start: u64 = 0, end: ?u64 = null };

pub const AudioFormat = struct {
    sample_rate: u32,
    channels: u16,
    /// WAVE speaker bits in channel order; null means unspecified source order.
    channel_mask: ?u32 = null,

    /// Return whether the output sample rate and channel layout agree.
    pub fn eql(a: AudioFormat, b: AudioFormat) bool {
        return a.sample_rate == b.sample_rate and a.channels == b.channels and a.channel_mask == b.channel_mask;
    }
};

/// Borrowed encoded bytes; submit must consume or copy them before returning.
pub const Packet = struct {
    bytes: []const u8,
    timestamp: ?Timestamp = null,
    duration: ?u64 = null,
};

/// Borrowed interleaved f32 samples, valid until the next codec operation.
pub const AudioBlock = struct {
    samples: []const f32,
    format: AudioFormat,
    timestamp: ?Timestamp = null,

    /// Return complete audio frames; codec output must be channel-aligned.
    pub fn frameCount(self: AudioBlock) usize {
        return self.samples.len / self.format.channels;
    }
};

pub const Submit = enum { accepted, receive_output_first };
pub const Receive = union(enum) { audio: AudioBlock, need_input, format_changed: AudioFormat, finished };

/// Stateful framing parser. Packets remain valid until the next parser call.
pub const BitstreamParser = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Result = struct { consumed: usize, packet: ?[]const u8 = null };
    pub const VTable = struct {
        /// eof permits emitting the final unit; incomplete trailing input is an error.
        parse: *const fn (*anyopaque, []const u8, bool) Error!Result,
        reset: *const fn (*anyopaque) void,
        deinit: *const fn (*anyopaque) void,
    };
};
