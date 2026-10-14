//! Audio metadata, sample formats, packet types, options, and errors.
const std = @import("std");

/// Audio container type.
pub const Format = enum { wav, wave64, ogg };

pub const PcmSampleType = enum {
    unsigned8,
    signed8,
    signed16,
    signed24,
    signed32,
    signed64,
    float32,
    float64,

    /// Return storage bytes per sample.
    pub fn byteSize(self: PcmSampleType) usize {
        return switch (self) {
            .unsigned8, .signed8 => 1,
            .signed16 => 2,
            .signed24 => 3,
            .signed32, .float32 => 4,
            .signed64, .float64 => 8,
        };
    }
};

/// Interleaved PCM storage. Reduced precision integers use the highest bits.
/// Null valid_bits means all storage bits are used.
pub const PcmFormat = struct {
    sample_type: PcmSampleType,
    byte_order: std.builtin.Endian,
    valid_bits: ?u16 = null,
};

/// Audio encoding, decoder support may vary.
pub const DecodingScheme = union(enum) {
    pcm: PcmFormat,
    opus: OpusConfig,
    alaw,
    mulaw,
    unsupported,
};

/// Ogg Opus mapping families 0 and 1, in Opus/Vorbis channel order.
pub const OpusConfig = struct {
    streams: u8 = 1,
    coupled_streams: u8 = 0,
    mapping: [8]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7 },
    /// Signed Q7.8 dB gain from OpusHead.
    gain_q8: i16 = 0,
};

/// Absolute byte range in source.
pub const DataRange = struct {
    offset: u64 = 0,
    length: u64 = 0,

    /// Return byte offset just past the range, overflow returns InvalidData.
    pub fn end(self: DataRange) ValidationError!u64 {
        return std.math.add(u64, self.offset, self.length)
            catch error.InvalidData;
    }
};

pub const AudioData = @import("AudioData.zig");
pub const Segment = AudioData.Segment;

/// Parsed metadata and borrowed audio segments.
pub const ParsedAudio = struct {
    info: Info,
    scheme: DecodingScheme,
    data: AudioData,
};

/// Audio metadata.
pub const Info = struct {
    format: Format,
    sample_rate: u32,
    channels: u16,
    /// One frame contains one sample for each channel. Null if unknown.
    total_frames: ?u64,
    /// True when decoded output has changed sample rate.
    variable_sample_rate: bool = false,

    /// Return duration in seconds, null if frame count is unknown or rate has
    /// changed.
    /// Sample rate must be nonzero.
    pub fn durationSeconds(self: Info) ?f64 {
        if (self.variable_sample_rate) return null;
        const frames = self.total_frames orelse return null;
        return @as(f64, @floatFromInt(frames))
            / @as(f64, @floatFromInt(self.sample_rate));
    }
};

/// Invalid audio metadata, sample format, or byte range.
pub const ValidationError = error{ InvalidData };

/// Container detection and metadata errors
pub const ParseError = error{
    UnsupportedFormat,
    UnsupportedChunkLayout,
    InvalidData,
    TruncatedData,
};

/// Sample decoding and decoder usage errors
pub const DecodeError = error{
    UnsupportedEncoding,
    InvalidData,
    TruncatedData,
    InvalidBufferSize,
    OutOfRange,
    LimitExceeded,
    InvalidState,
    FormatChanged,
};

pub const ReadError = std.Io.Reader.Error;
pub const SeekError = std.Io.File.Reader.SeekError;
/// Seeking a source whose seek callback may be unavailable.
pub const SourceSeekError = SeekError || error{ Unseekable };
pub const SizeError = std.Io.File.Reader.SizeError || error{ Unseekable };

/// Errors from accessing the source
pub const IoError = ReadError || SeekError || SizeError;

/// Complete container parser errors, including source access.
pub const ParserError = ParseError || IoError;

/// Complete decoder pipeline errors, including parsing, I/O, and allocation.
pub const DecoderError = ParseError
    || DecodeError
    || IoError
    || std.mem.Allocator.Error;

pub const Error = DecoderError;

pub const Options = struct {
    /// Maximum bytes retained for one packet or configuration payload.
    max_payload_bytes: usize = 64 * 1024 * 1024,
    /// Maximum memory occupied by Ogg and segmented WAVE seek indexes.
    max_index_bytes: usize = 64 * 1024 * 1024,
    /// Working input capacity allocated during initialization, capped by
    /// max_payload_bytes. Used by Ogg packet assembly, Framer, WAVE
    /// input/format
    /// storage, and fixed-unit codec input/output sizing.
    /// Larger packets/configuration chunks return LimitExceeded.
    buffer_bytes: usize = 64 * 1024,
    /// Reserve last-frame history for at least this many channels in Decoder.
    /// The initial channel count is also accommodated. Later format changes
    /// exceeding the reserved capacity return LimitExceeded.
    reserve_channels: u16 = 8,

    pub fn bufferCapacity(self: Options) usize {
        return @min(self.buffer_bytes, self.max_payload_bytes);
    }
};

pub const InputScheme = union(enum) {
    samples: u32,
    blocks: u32,
    packets,

    /// Return bytes per complete input unit, or null for packet framing.
    pub fn unitBytes(self: InputScheme) ?u32 {
        return switch (self) {
            .samples, .blocks => |size| size,
            .packets => null,
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
    pub fn eql(self: AudioFormat, other: AudioFormat) bool {
        return self.sample_rate == other.sample_rate
            and self.channels == other.channels
            and self.channel_mask == other.channel_mask;
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
pub const Receive = union(enum) {
    audio: AudioBlock,
    need_input,
    format_changed: AudioFormat,
    finished,
};
