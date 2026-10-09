const std = @import("std");

/// Audio container type.
pub const Format = enum { wav };

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
    alaw,
    mulaw,
    unsupported,
};

/// Absolute byte range in source.
pub const DataRange = struct {
    offset: u64 = 0,
    length: u64 = 0,

    /// Return byte offset just past the range, overflow returns InvalidData.
    pub fn end(self: DataRange) error{InvalidData}!u64 {
        return std.math.add(u64, self.offset, self.length) catch error.InvalidData;
    }
};

/// Parsed metadata and encoded audio range.
pub const ParsedAudio = struct {
    info: Info,
    scheme: DecodingScheme,
    data: DataRange,
};

/// Audio metadata.
pub const Info = struct {
    format: Format,
    sample_rate: u32,
    channels: u16,
    /// One frame contains one sample for each channel. Null if unknown.
    total_frames: ?u64,

    /// Return duration in seconds, null if frame count is unknown.
    /// Sample rate must be nonzero.
    pub fn durationSeconds(self: Info) ?f64 {
        const frames = self.total_frames orelse return null;
        return @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(self.sample_rate));
    }
};

/// Container detection and metadata errors, independent of source I/O.
pub const ParseError = error{
    UnsupportedFormat,
    UnsupportedChunkLayout,
    InvalidData,
    TruncatedData,
};

/// Sample decoding and decoder usage errors, independent of source I/O.
pub const DecodeError = error{
    UnsupportedEncoding,
    InvalidData,
    TruncatedData,
    InvalidBufferSize,
    OutOfRange,
};

pub const ReadError = std.Io.Reader.Error;
pub const SeekError = std.Io.File.Reader.SeekError;
pub const SizeError = std.Io.File.Reader.SizeError || error{Unseekable};

/// Errors from accessing the source, independent of audio format.
pub const IoError = ReadError || SeekError || SizeError;
