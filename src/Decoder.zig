//! Decodes interleaved f32 samples in source channel order and at the source sample rate.
//! Integer samples are normalized to [-1, 1]; floating-point samples retain their scale.
const types = @import("types.zig");
const parsers = @import("parsers.zig");
const pcm = @import("decoders/pcm.zig");
const SeekableReader = @import("SeekableReader.zig");
const Decoder = @This();

pub const Error = types.ParseError || types.DecodeError || types.IoError;

metadata: types.Info,
source: SeekableReader,
data: types.AudioData,
segments: types.AudioData.Iterator,
current: ?types.Segment = null,
segment_offset: u64 = 0,
frame_offset: u64 = 0,
/// Last encoded frame before silence, retained by location
previous_frame: ?types.DataRange = null,
backend: union(enum) {
    pcm: struct { format: types.PcmFormat, decoder: ?pcm.Decoder = null },
},
failure: ?Error = null,

/// Open audio for decoding, borrows exclusive access to source until deinit.
/// Keep the reader and buffer in place, keep input open and unchanged.
pub fn init(source: SeekableReader) Error!Decoder {
    return initParsed(source, try parsers.parse(source));
}

/// Open parsed audio for decoding, use the same unchanged source.
/// Borrows exclusive access until deinit. Keep reader and buffer in place.
pub fn initParsed(source: SeekableReader, parsed: types.ParsedAudio) Error!Decoder {
    if (parsed.info.sample_rate == 0 or parsed.info.channels == 0) return error.InvalidData;
    const format = switch (parsed.scheme) {
        .pcm => |format| format,
        else => return error.UnsupportedEncoding,
    };
    try pcm.validateFormat(format);
    const block_align = @as(u32, parsed.info.channels) * @as(u32, @intCast(format.sample_type.byteSize()));
    const frames = try parsed.data.frameCount(source, block_align);
    if (parsed.info.total_frames) |declared| {
        if (declared != frames) return error.InvalidData;
    }
    var result = Decoder{
        .metadata = parsed.info,
        .source = source,
        .data = parsed.data,
        .segments = parsed.data.iterate(source),
        .backend = .{ .pcm = .{ .format = format } },
    };
    result.metadata.total_frames = frames;
    try result.seekFrame(0);
    return result;
}

/// Release decoder state, input remains open and owned by caller.
pub fn deinit(self: *Decoder) void {
    self.* = undefined;
}

/// Return audio metadata.
pub fn info(self: *const Decoder) types.Info {
    return self.metadata;
}

/// Return the encoded byte size of one frame.
fn blockAlign(self: *const Decoder) u32 {
    return switch (self.backend) {
        .pcm => |backend| @as(u32, self.metadata.channels) * @as(u32, @intCast(backend.format.sample_type.byteSize())),
    };
}

/// Select a segment and seek to a frame offset within it.
fn activate(self: *Decoder, segment: types.Segment, offset: u64) Error!void {
    switch (self.backend) {
        .pcm => |*backend| {
            backend.decoder = switch (segment) {
                .data => |range| try pcm.Decoder.init(self.source, range, self.metadata.channels, backend.format),
                .silence => null,
            };
            if (backend.decoder) |*decoder| try decoder.seekFrame(offset);
        },
    }
    self.current = segment;
    self.segment_offset = offset;
}

/// Select the next nonempty segment; return false at end of input.
fn advance(self: *Decoder) Error!bool {
    while (try self.segments.next()) |segment| {
        if (try segment.frameCount(self.blockAlign()) == 0) continue;
        try self.activate(segment, 0);
        return true;
    }
    self.current = null;
    return false;
}

/// Return frames written to out, leaving the unused tail untouched; zero means EOF.
/// out must be nonempty and its length a multiple of the channel count.
/// After an input error, discard output and seek successfully before reading again.
pub fn read(self: *Decoder, out: []f32) Error!usize {
    if (out.len == 0 or out.len % self.metadata.channels != 0) return error.InvalidBufferSize;
    if (self.failure) |failure| return failure;
    return self.readSegments(out) catch |err| {
        self.failure = err;
        return err;
    };
}

/// Fill a whole-frame buffer across segments and return the number of frames written.
fn readSegments(self: *Decoder, out: []f32) Error!usize {
    const channels = self.metadata.channels;
    const frames: usize = @intCast(@min(out.len / channels, self.metadata.total_frames.? - self.frame_offset));
    var written: usize = 0;
    while (written < frames) {
        if (self.current == null and !try self.advance()) return error.TruncatedData;
        const segment = self.current.?;
        const remaining = try segment.frameCount(self.blockAlign()) - self.segment_offset;
        const count: usize = @intCast(@min(frames - written, remaining));
        const samples = out[written * channels ..][0 .. count * channels];
        switch (segment) {
            .data => |range| {
                const read_frames = switch (self.backend) {
                    .pcm => |*backend| try backend.decoder.?.read(samples),
                };
                if (read_frames != count) return error.TruncatedData;
                self.previous_frame = .{
                    .offset = range.offset + (self.segment_offset + count - 1) * self.blockAlign(),
                    .length = self.blockAlign(),
                };
            },
            .silence => try self.readSilence(samples),
        }
        written += count;
        self.segment_offset += count;
        if (count == remaining) self.current = null;
    }
    self.frame_offset += frames;
    return frames;
}

/// Fill whole frames by repeating the preceding frame, or zeros if none exists.
fn readSilence(self: *Decoder, out: []f32) Error!void {
    const channels = self.metadata.channels;
    if (self.previous_frame) |range| {
        switch (self.backend) {
            .pcm => |backend| {
                var decoder = try pcm.Decoder.init(self.source, range, channels, backend.format);
                if (try decoder.read(out[0..channels]) != 1) return error.TruncatedData;
            },
        }
        var offset: usize = channels;
        while (offset < out.len) : (offset += channels) {
            @memcpy(out[offset..][0..channels], out[0..channels]);
        }
    } else {
        @memset(out, 0);
    }
}

/// Seek to an absolute frame, clearing any prior input error on success.
/// The total frame count is EOF; larger positions return OutOfRange.
pub fn seekFrame(self: *Decoder, frame: u64) Error!void {
    if (frame > self.metadata.total_frames.?) return error.OutOfRange;
    self.seekSegments(frame) catch |err| {
        self.failure = err;
        return err;
    };
    self.frame_offset = frame;
    self.failure = null;
}

/// Locate an in-range absolute frame and restore the preceding frame for silence.
fn seekSegments(self: *Decoder, frame: u64) Error!void {
    self.segments = self.data.iterate(self.source);
    self.current = null;
    self.previous_frame = null;
    if (frame == self.metadata.total_frames.?) return;
    var remaining = frame;
    while (try self.segments.next()) |segment| {
        const frames = try segment.frameCount(self.blockAlign());
        if (remaining < frames) {
            try self.activate(segment, remaining);
            return;
        }
        remaining -= frames;
        if (segment == .data and frames != 0) {
            self.previous_frame = .{
                .offset = try segment.data.end() - self.blockAlign(),
                .length = self.blockAlign(),
            };
        }
    }
    return error.TruncatedData;
}

/// Return frame position after the last successful read or seek.
pub fn tellFrame(self: *const Decoder) u64 {
    return self.frame_offset;
}
