//! borrow audio ranges through a shared segment iterator.
const std = @import("std");
const types = @import("types.zig");
const Source = @import("Source.zig");
const riff = @import("containers/wave/riff.zig");
const AudioData = @This();

pub const Segment = union(enum) {
    data: types.DataRange,
    /// repeat the preceding frame, or output zeros before any data.
    silence: u64,

    /// count frames using nonzero block_align; reject partial frames.
    pub fn frameCount(
        self: Segment,
        block_align: u32,
    ) types.ValidationError!u64 {
        if (block_align == 0) return error.InvalidData;
        return switch (self) {
            .data => |range| {
                if (range.length % block_align != 0) return error.InvalidData;
                return range.length / block_align;
            },
            .silence => |frames| frames,
        };
    }
};

layout: union(enum) { single: Segment, wavl: riff.SegmentList },

/// wrap one data or silence segment.
pub fn single(segment: Segment) AudioData {
    return .{ .layout = .{ .single = segment } };
}

/// iterate in playback order; may seek input, which must stay unchanged.
pub fn iterate(self: AudioData, source: Source) Iterator {
    return .{
        .state = switch (self.layout) {
            .single => |segment| .{ .single = segment },
            .wavl => |list| .{ .wavl = list.iterate(source) },
        },
    };
}

/// validate bounds and sum frames; block_align must be nonzero.
/// may seek the source.
pub fn frameCount(
    self: AudioData,
    source: Source,
    block_align: u32,
) types.ParserError!u64 {
    if (block_align == 0) return error.InvalidData;
    const size = try source.getSize() orelse return error.Unseekable;
    var segments = self.iterate(source);
    var frames: u64 = 0;
    while (try segments.next()) |segment| {
        if (segment == .data and try segment.data.end() > size) {
            return error.TruncatedData;
        }
        frames = std.math.add(u64, frames, try segment.frameCount(block_align))
            catch return error.InvalidData;
    }
    return frames;
}

pub const Iterator = struct {
    state: union(enum) { single: ?Segment, wavl: riff.SegmentIterator },

    /// return the next segment, including empty ones, or null at the end.
    pub fn next(self: *Iterator) types.ParserError!?Segment {
        switch (self.state) {
            .single => |*segment| {
                const result = segment.*;
                segment.* = null;
                return result;
            },
            .wavl => |*list| return list.next(),
        }
    }
};
