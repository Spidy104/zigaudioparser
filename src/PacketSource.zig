//! Container reader interface: borrowed file bytes become encoded packets and
//! events.
const std = @import("std");
const types = @import("types.zig");
const Source = @import("Source.zig");
const Wave = @import("containers/wave/Wave.zig");
const Ogg = @import("containers/ogg/Ogg.zig");
const PacketSource = @This();

backend: union(enum) { wave: *Wave, ogg: *Ogg },
encoding: types.DecodingScheme,
format: types.AudioFormat,
presentation: types.Presentation = .{},
/// Decoded position of the first sample, before presentation trimming.
decoded_origin: i64 = 0,
seekable: bool,
max_payload_bytes: usize = 64 * 1024 * 1024,

pub const Event = union(enum) {
    packet: types.Packet,
    /// Supply final presentation bounds before emitting the affected packets.
    presentation: types.Presentation,
    /// WAVE slnt holds the last decoded frame without advancing codec state.
    silence: u64,
    end,
};

pub const SeekResult = struct { frame: i64 };

/// Detect WAV/Wave64 or Ogg Opus. Seekable Ogg and segmented WAVE inputs are
/// indexed; sequential inputs are parsed incrementally.
/// Allocates source state, fixed working buffers, and any seek index here.
pub fn init(
    allocator: std.mem.Allocator,
    source: Source,
    options: types.Options,
) types.Error!PacketSource {
    const seekable = source.seek_to != null
        and source.get_size != null
        and try source.getSize() != null;
    if (seekable) try source.seekTo(0);
    var prefix: [4]u8 = undefined;
    if (try source.reader.readSliceShort(&prefix) != prefix.len) {
        return error.UnsupportedFormat;
    }
    if (std.mem.eql(u8, &prefix, "OggS")) {
        return Ogg.init(allocator, source, prefix, options);
    }
    if (Wave.probe(&prefix)) {
        return Wave.init(allocator, source, prefix, options);
    }
    return error.UnsupportedFormat;
}

/// Open an unchanged parsed WAV/Wave64 layout with seek and size capabilities.
pub fn initParsed(
    allocator: std.mem.Allocator,
    source: Source,
    parsed: types.ParsedAudio,
    options: types.Options,
) types.Error!PacketSource {
    return Wave.initParsed(allocator, source, parsed, options);
}

/// Set input framing before requesting packets.
pub fn configure(
    self: *PacketSource,
    scheme: types.InputScheme,
) types.Error!void {
    switch (self.backend) {
        .wave => |wave| try wave.configure(scheme),
        .ogg => |ogg| try ogg.configure(scheme),
    }
}

/// Borrow the next packet until the next advancing source operation.
pub fn next(self: *PacketSource) types.Error!Event {
    const event = switch (self.backend) {
        .wave => |wave| try wave.next(),
        .ogg => |ogg| try ogg.next(),
    };
    if (event == .packet) {
        if (event.packet.bytes.len == 0) return error.InvalidData;
        if (event.packet.bytes.len > self.max_payload_bytes) {
            return error.LimitExceeded;
        }
    }
    return event;
}

/// Return metadata; source frame counts include samples removed by presentation
/// trimming.
pub fn info(self: *const PacketSource) types.Info {
    return switch (self.backend) {
        .wave => |wave| wave.info(),
        .ogg => |ogg| ogg.info(),
    };
}

/// Seek at or before a decoded frame, retaining enough context for container
/// silence.
pub fn seek(self: *PacketSource, frame: u64) types.Error!SeekResult {
    if (!self.seekable) return error.Unseekable;
    return switch (self.backend) {
        .wave => |wave| wave.seek(frame),
        .ogg => |ogg| ogg.seek(frame),
    };
}

/// Release packet storage and parser state; borrowed input remains open.
pub fn deinit(self: *PacketSource) void {
    switch (self.backend) {
        .wave => |wave| wave.deinit(),
        .ogg => |ogg| ogg.deinit(),
    }
    self.* = undefined;
}
