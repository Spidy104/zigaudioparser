const types = @import("types.zig");
const parsers = @import("parsers.zig");
const pcm = @import("decoders/pcm.zig");
const SeekableReader = @import("SeekableReader.zig");
const Decoder = @This();

metadata: types.Info,
backend: union(enum) { pcm: pcm.Decoder },
/// Open audio for decoding, borrows exclusive access to source until deinit.
/// Keep the reader and buffer in place, keep input open and unchanged.
pub fn init(source: SeekableReader) (types.ParseError || types.DecodeError || types.IoError)!Decoder {
    return initParsed(source, try parsers.parse(source));
}

/// Open parsed audio for decoding, use the same unchanged source.
/// Borrows exclusive access until deinit. Keep reader and buffer in place.
pub fn initParsed(source: SeekableReader, parsed: types.ParsedAudio) (types.DecodeError || types.SeekError || types.SizeError)!Decoder {
    if (parsed.info.sample_rate == 0 or parsed.info.channels == 0) return error.InvalidData;
    const backend: @FieldType(Decoder, "backend") = switch (parsed.scheme) {
        .pcm => |format| .{ .pcm = try pcm.Decoder.init(source, parsed.data, parsed.info.channels, format) },
        else => return error.UnsupportedEncoding,
    };
    var metadata = parsed.info;
    const frames = backend.pcm.frameCount();
    if (metadata.total_frames) |declared| {
        if (declared != frames) return error.InvalidData;
    }
    metadata.total_frames = frames;
    return .{ .metadata = metadata, .backend = backend };
}

/// Release decoder state, input remains open and owned by caller.
pub fn deinit(self: *Decoder) void {
    self.* = undefined;
}

/// Return audio metadata.
pub fn info(self: *const Decoder) types.Info {
    return self.metadata;
}

/// Read interleaved samples, returns frames read, zero means end of input.
/// Buffer must be nonempty, length must be a multiple of channel count.
/// Keeps source channel order and sample rate. Integer samples scaled from
/// minus one to one, floating samples keep their scale. After an input error,
/// discard output and seek successfully before reading again.
pub fn read(self: *Decoder, out: []f32) (types.DecodeError || types.ReadError || types.SeekError)!usize {
    const channels = self.info().channels;
    if (out.len == 0 or out.len % channels != 0) return error.InvalidBufferSize;
    return switch (self.backend) {
        .pcm => |*decoder| decoder.read(out),
    };
}

/// Seek to an absolute frame, total frame count means end of input.
/// Positions beyond end return OutOfRange. After an input error, seek again.
pub fn seekFrame(self: *Decoder, frame: u64) (types.DecodeError || types.SeekError)!void {
    return switch (self.backend) {
        .pcm => |*decoder| decoder.seekFrame(frame),
    };
}

/// Return frame position after last successful read or seek.
pub fn tellFrame(self: *const Decoder) u64 {
    return switch (self.backend) {
        .pcm => |decoder| decoder.frame_offset,
    };
}
