//! WAVE LIST/wavl children
const std = @import("std");
const types = @import("../types.zig");
const Segment = @import("../AudioData.zig").Segment;
const SeekableReader = @import("../SeekableReader.zig");
const riff = @import("riff.zig");
const common = @import("common.zig");

pub const List = struct {
    /// Child chunks only, excluding the LIST header and wavl FourCC.
    children: types.DataRange,
    byte_order: std.builtin.Endian,

    /// Iterate data and silence segments; keep source contents unchanged while iterating.
    pub fn iterate(self: List, source: SeekableReader) Iterator {
        return .{ .source = source, .list = self, .offset = self.children.offset };
    }
};

pub const Iterator = struct {
    source: SeekableReader,
    list: List,
    offset: u64,

    /// Return the next data or silence segment, skipping other chunks; null means end of list.
    /// Repositions source. Nested wavl lists return UnsupportedChunkLayout.
    pub fn next(self: *Iterator) common.ParseError!?Segment {
        const end = try self.list.children.end();
        while (self.offset != end) {
            const header = try riff.readHeader(self.source, self.offset, end, self.list.byte_order);
            const chunk = try riff.frame(header, self.offset, end);
            self.offset = chunk.next_offset;
            if (std.mem.eql(u8, &header.id, "data")) return .{ .data = chunk.data };
            if (std.mem.eql(u8, &header.id, "slnt")) {
                if (header.size != 4) return error.InvalidData; // 4 = 32-bit frame count.
                var count: [4]u8 = undefined;
                try common.readRequired(self.source, &count);
                return .{ .silence = std.mem.readInt(u32, &count, self.list.byte_order) };
            }
            if (std.mem.eql(u8, &header.id, "LIST")) {
                if (header.size < 4) return error.InvalidData; // 4 = LIST type FourCC.
                var kind: [4]u8 = undefined;
                try common.readRequired(self.source, &kind);
                if (std.mem.eql(u8, &kind, "wavl")) return error.UnsupportedChunkLayout;
            }
        }
        return null;
    }
};
