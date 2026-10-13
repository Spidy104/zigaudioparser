//! Forward-only WAVE and Wave64 chunk processing.
const std = @import("std");
const types = @import("../types.zig");
const decoding = @import("../decoding.zig");
const Source = @import("../Source.zig");
const SeekableReader = @import("../SeekableReader.zig");
const riff = @import("riff.zig");
const wav = @import("wav.zig");
const wave64 = @import("wave64.zig");
const wave_format = @import("wave_format.zig");
const WaveStream = @This();

allocator: std.mem.Allocator,
source: Source,
options: decoding.Options,
position: u64 = 0,
end: u64 = 0,
next_offset: u64 = 0,
kind: types.Format = .wav,
byte_order: std.builtin.Endian = .little,
format: ?wave_format.FormatChunk = null,
format_bytes: []u8 = &.{},
fact: ?u64 = null,
ds64: ?struct { data_size: u64, sample_count: ?u64 } = null,
table: []u8 = &.{},
table_offset: usize = 0,
seen_data: bool = false,
segmented: bool = false,
wavl_end: ?u64 = null,
wavl_next: u64 = 0,
frames: u64 = 0,
data_size: u64 = 0,
data_chunk_size: u64 = 0,
finished: bool = false,

/// Read the container header. Input must be positioned at its beginning.
pub fn init(allocator: std.mem.Allocator, source: Source, options: decoding.Options) decoding.Error!WaveStream {
    var self = WaveStream{ .allocator = allocator, .source = source, .options = options };
    errdefer self.deinit();
    var bytes: [40]u8 = undefined;
    // Short or empty unrecognized prefixes preserve container detection errors.
    var prefix_len: usize = 0;
    while (prefix_len < 4) : (prefix_len += 1) {
        bytes[prefix_len] = source.reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return error.UnsupportedFormat,
            else => return err,
        };
    }
    self.position = 4;
    if (wav.probe(bytes[0..4])) {
        try self.read(bytes[4..12]);
        if (!std.mem.eql(u8, bytes[8..12], "WAVE")) return error.UnsupportedFormat;
        self.byte_order = if (std.mem.eql(u8, bytes[0..4], "RIFX")) .big else .little;
        const size = std.mem.readInt(u32, bytes[4..8], self.byte_order);
        const extended = std.mem.eql(u8, bytes[0..4], "RF64") or std.mem.eql(u8, bytes[0..4], "BW64");
        if (extended) {
            if (size != std.math.maxInt(u32)) return error.InvalidData;
            var header: [8]u8 = undefined;
            try self.read(&header);
            const ds_size = std.mem.readInt(u32, header[4..8], .little);
            if (!std.mem.eql(u8, header[0..4], "ds64") or ds_size < 28 or ds_size == std.math.maxInt(u32)) return error.InvalidData;
            var ds: [28]u8 = undefined;
            try self.read(&ds);
            self.end = std.math.add(u64, std.mem.readInt(u64, ds[0..8], .little), 8) catch return error.InvalidData;
            self.ds64 = .{ .data_size = std.mem.readInt(u64, ds[8..16], .little), .sample_count = if (std.mem.eql(u8, bytes[0..4], "RF64")) std.mem.readInt(u64, ds[16..24], .little) else null };
            const table_size = @as(u64, std.mem.readInt(u32, ds[24..28], .little)) * 12;
            if (table_size > ds_size - 28) return error.InvalidData;
            if (table_size > options.max_payload_bytes) return error.LimitExceeded;
            self.table = try allocator.alloc(u8, @intCast(table_size));
            try self.read(self.table);
            self.next_offset = 20 + @as(u64, ds_size) + (ds_size & 1);
        } else {
            if (size < 4) return error.InvalidData;
            self.end = @as(u64, size) + 8;
            self.next_offset = 12;
        }
    } else if (wave64.probe(bytes[0..4])) {
        try self.read(bytes[4..40]);
        if (!std.mem.eql(u8, bytes[0..16], &wave64.riff_guid) or !std.mem.eql(u8, bytes[24..40], &wave64.wave_guid)) return error.UnsupportedFormat;
        self.kind = .wave64;
        self.end = std.mem.readInt(u64, bytes[16..24], .little);
        if (self.end < 40) return error.InvalidData;
        self.next_offset = 40;
    } else return error.UnsupportedFormat;
    if (self.next_offset > self.end) return error.InvalidData;
    return self;
}

/// Release retained size overrides; the source remains open.
pub fn deinit(self: *WaveStream) void {
    self.allocator.free(self.table);
    self.allocator.free(self.format_bytes);
}

/// Read required bytes and advance the absolute stream position.
pub fn read(self: *WaveStream, out: []u8) decoding.Error!void {
    self.source.reader.readSliceAll(out) catch |err| return switch (err) {
        error.EndOfStream => error.TruncatedData,
        else => err,
    };
    self.position = std.math.add(u64, self.position, out.len) catch return error.InvalidData;
}

/// Consume bytes up to an absolute forward position.
fn skipTo(self: *WaveStream, offset: u64) decoding.Error!void {
    if (offset < self.position) return error.InvalidState;
    var scratch: [8192]u8 = undefined;
    while (self.position < offset) try self.read(scratch[0..@intCast(@min(scratch.len, offset - self.position))]);
}

/// Return the next audio segment, leaving input at its first byte.
pub fn next(self: *WaveStream) decoding.Error!?types.Segment {
    if (self.finished) return null;
    while (true) {
        if (self.wavl_end) |end| {
            if (self.next_offset == end) {
                self.wavl_end = null;
                self.next_offset = self.wavl_next;
            }
        }
        if (self.next_offset == self.end) {
            try self.skipTo(self.end);
            try self.validateEnd();
            self.finished = true;
            return null;
        }
        const end = self.wavl_end orelse self.end;
        if (self.next_offset > end) return error.InvalidData;
        if (self.kind == .wave64 and end - self.next_offset < 24 and self.seen_data) {
            // Wave64 permits an incomplete trailing alignment header after data.
            try self.validateEnd();
            self.finished = true;
            return null;
        }
        try self.skipTo(self.next_offset);
        const chunk = try self.readChunk(end);
        const id = chunk.header.id;
        if (std.mem.eql(u8, &id, "fmt ") and self.wavl_end == null) {
            if (self.format != null) return error.InvalidData;
            if (chunk.data.length > self.options.max_payload_bytes) return error.LimitExceeded;
            self.format_bytes = try self.allocator.alloc(u8, @intCast(chunk.data.length));
            const bytes = self.format_bytes;
            try self.read(bytes);
            var reader = std.Io.Reader.fixed(bytes);
            const fixed = SeekableReader.fromFixed(&reader);
            const range = types.DataRange{ .length = bytes.len };
            self.format = if (self.kind == .wave64) try wave_format.parseWave64(fixed, range) else try wave_format.parse(fixed, range, self.byte_order);
        } else if (std.mem.eql(u8, &id, "fact") and self.wavl_end == null) {
            const size: usize = if (self.kind == .wave64) 8 else 4;
            if (self.fact != null or chunk.data.length < size) return error.InvalidData;
            var bytes: [8]u8 = undefined;
            try self.read(bytes[0..size]);
            self.fact = if (size == 8) std.mem.readInt(u64, &bytes, .little) else std.mem.readInt(u32, bytes[0..4], self.byte_order);
        } else if (std.mem.eql(u8, &id, "data")) {
            const fmt = self.format orelse return error.InvalidData;
            if (self.wavl_end == null) {
                if (self.seen_data) return error.UnsupportedChunkLayout;
                self.seen_data = true;
            }
            self.data_size = chunk.data.length;
            self.data_chunk_size = chunk.header.size;
            if (self.kind != .wave64 and chunk.data.length % fmt.block_align != 0) return error.InvalidData;
            self.frames = std.math.add(u64, self.frames, chunk.data.length / fmt.block_align) catch return error.InvalidData;
            return .{ .data = chunk.data };
        } else if (std.mem.eql(u8, &id, "slnt") and self.wavl_end != null) {
            if (chunk.data.length != 4) return error.InvalidData;
            var bytes: [4]u8 = undefined;
            try self.read(&bytes);
            const count = std.mem.readInt(u32, &bytes, self.byte_order);
            self.frames = std.math.add(u64, self.frames, count) catch return error.InvalidData;
            return .{ .silence = count };
        } else if (std.mem.eql(u8, &id, "LIST") and self.kind == .wav) {
            if (chunk.data.length < 4) return error.InvalidData;
            var kind: [4]u8 = undefined;
            try self.read(&kind);
            if (std.mem.eql(u8, &kind, "wavl")) {
                if (self.wavl_end != null or self.seen_data or self.ds64 != null) return error.UnsupportedChunkLayout;
                if (self.format == null) return error.InvalidData;
                self.seen_data = true;
                self.segmented = true;
                self.wavl_end = try chunk.data.end();
                self.wavl_next = self.next_offset;
                self.next_offset = self.position;
            }
        }
    }
}

fn readChunk(self: *WaveStream, end: u64) decoding.Error!riff.Chunk {
    const offset = self.position;
    if (self.kind == .wave64) {
        if (end - offset < 24) return error.InvalidData;
        var bytes: [24]u8 = undefined;
        try self.read(&bytes);
        const size = std.mem.readInt(u64, bytes[16..24], .little);
        if (size < 24 or size > end - offset) return error.InvalidData;
        var id: [4]u8 = .{ 0, 0, 0, 0 };
        if (std.mem.eql(u8, bytes[4..16], wave64.data_guid[4..])) id = bytes[0..4].*;
        self.next_offset = offset + size;
        if (!std.mem.eql(u8, &id, "data")) self.next_offset += @min((8 - (size & 7)) & 7, end - self.next_offset);
        return .{ .header = .{ .id = id, .size = size }, .data = .{ .offset = self.position, .length = size - 24 }, .next_offset = self.next_offset };
    }
    if (end - offset < 8) return error.InvalidData;
    var bytes: [8]u8 = undefined;
    try self.read(&bytes);
    var header = riff.ChunkHeader{ .id = bytes[0..4].*, .size = std.mem.readInt(u32, bytes[4..8], self.byte_order) };
    if (self.ds64) |ds| {
        if (std.mem.eql(u8, &header.id, "ds64")) return error.InvalidData;
        if (header.size == std.math.maxInt(u32)) {
            if (std.mem.eql(u8, &header.id, "data") and !self.seen_data) {
                header.size = ds.data_size;
            } else {
                if (self.table_offset == self.table.len) return error.InvalidData;
                const entry = self.table[self.table_offset..][0..12];
                if (!std.mem.eql(u8, &header.id, entry[0..4])) return error.InvalidData;
                header.size = std.mem.readInt(u64, entry[4..12], .little);
                self.table_offset += 12;
            }
        }
    }
    const result = try riff.frame(header, offset, end);
    self.next_offset = result.next_offset;
    return result;
}

/// Resolve Wave64's possible trailing sample padding after all metadata is read.
pub fn wave64DataLength(self: *const WaveStream) decoding.Error!u64 {
    const alignment = self.format.?.block_align;
    const length = if (self.fact) |frames| std.math.mul(u64, frames, alignment) catch return error.InvalidData else self.data_size - self.data_size % alignment;
    if (length > self.data_size or self.data_size - length > 7) return error.InvalidData;
    if (length != self.data_size and self.data_chunk_size & 7 != 0) return error.InvalidData;
    return length;
}

fn validateEnd(self: *WaveStream) decoding.Error!void {
    const fmt = self.format orelse return error.InvalidData;
    if (!self.seen_data) return error.InvalidData;
    if (self.kind == .wave64) {
        self.frames = try self.wave64DataLength() / fmt.block_align;
    } else {
        if ((fmt.encoding() != .pcm or self.segmented) and self.fact == null and self.ds64 == null) return error.InvalidData;
        if (self.segmented and self.fact.? != self.frames) return error.InvalidData;
    }
}
