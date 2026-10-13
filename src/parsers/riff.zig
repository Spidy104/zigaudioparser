//! RIFF-family framing.
//! RF64: EBU Tech 3306. BW64: ITU-R BS.2088.
const std = @import("std");
const types = @import("../types.zig");
const SeekableReader = @import("../SeekableReader.zig");

const common = @import("common.zig");
pub const Error = types.ParserError;
const readRequired = common.readRequired;

pub const ChunkHeader = common.ChunkHeader;

pub const RiffHeader = struct {
    chunk: ChunkHeader, // RIFF, RIFX, RF64 or BW64; resolved file size minus 8
    format: [4]u8, // Form type; interpreted by the caller.

    /// Return big-endian for RIFX, little-endian otherwise.
    pub fn byteOrder(self: RiffHeader) std.builtin.Endian {
        return if (std.mem.eql(u8, &self.chunk.id, "RIFX")) .big else .little;
    }
};

pub const DataSize64 = struct {
    riff_size: u64,
    data_size: u64,
    /// RF64 samples per channel; zero means unspecified. Null for BW64.
    sample_count: ?u64,
    /// Borrowed array of 12-byte entries: FourCC followed by a little-endian u64.
    table: types.DataRange,
};

pub const Chunk = struct {
    header: ChunkHeader,
    data: types.DataRange,
    next_offset: u64,
};

/// Read a chunk header at offset, bounded by the exclusive end; leaves source at its payload.
pub fn readHeader(source: SeekableReader, offset: u64, end: u64, byte_order: std.builtin.Endian) Error!ChunkHeader {
    // 8 = FourCC + 32-bit payload size.
    if (offset > end or end - offset < 8) return error.InvalidData;
    try source.seekTo(offset);
    var bytes: [8]u8 = undefined;
    try readRequired(source, &bytes);
    return .{ .id = bytes[0..4].*, .size = std.mem.readInt(u32, bytes[4..8], byte_order) };
}

/// Resolve payload and next-header offsets, validating bounds and padding against end.
/// offset is the header position; header.size must already include any ds64 override.
pub fn frame(header: ChunkHeader, offset: u64, end: u64) Error!Chunk {
    // 8 = chunk header length.
    if (offset > end or end - offset < 8) return error.InvalidData;
    const payload_offset = offset + 8;
    if (header.size > end - payload_offset) return error.InvalidData;
    const payload_end = payload_offset + header.size;
    const padding = header.size & 1; // 1 = pad byte for an odd payload length.
    if (padding > end - payload_end) return error.InvalidData;
    return .{
        .header = header,
        .data = .{ .offset = payload_offset, .length = header.size },
        .next_offset = payload_end + padding,
    };
}

/// Borrows the source; next() always seeks to the returned payload.
/// Position is unspecified on error, don't resume an iterator after an error.
pub const Iterator = struct {
    source: SeekableReader,
    header: RiffHeader,
    ds64: ?DataSize64 = null,
    offset: u64,
    end: u64,
    table_offset: u64 = 0,
    seen_data: bool = false,

    /// Read the RIFF-family header and optional ds64 sizes from the start of source.
    /// Keep input unchanged while using the iterator and returned ranges.
    pub fn init(source: SeekableReader) Error!Iterator {
        const source_size = try source.getSize();
        if (source_size < 12) return error.TruncatedData; // 12 = RIFF header including form type.
        try source.seekTo(0);
        var bytes: [12]u8 = undefined;
        try readRequired(source, &bytes);
        const id = bytes[0..4].*;
        const extended = std.mem.eql(u8, &id, "RF64") or std.mem.eql(u8, &id, "BW64");
        const byte_order: std.builtin.Endian = if (std.mem.eql(u8, &id, "RIFX")) .big else .little;
        if (!extended and byte_order != .big and !std.mem.eql(u8, &id, "RIFF")) return error.UnsupportedFormat;

        var result = Iterator{
            .source = source,
            .header = .{
                .chunk = .{ .id = id, .size = std.mem.readInt(u32, bytes[4..8], byte_order) },
                .format = bytes[8..12].*,
            },
            .offset = 12,
            .end = source_size,
        };
        if (extended) {
            if (result.header.chunk.size != std.math.maxInt(u32)) return error.InvalidData;
            // 12 = ds64 chunk offset; 8 = its chunk header length.
            if (source_size - 12 < 8) return error.TruncatedData;
            const ds_header = try readHeader(source, 12, source_size, .little);
            // 28 = three 64-bit values + 32-bit table entry count.
            if (!std.mem.eql(u8, &ds_header.id, "ds64") or ds_header.size < 28 or
                ds_header.size == std.math.maxInt(u32)) return error.InvalidData;
            if (ds_header.size > source_size - 20) return error.TruncatedData; // 20 = ds64 payload offset.
            const ds_chunk = try frame(ds_header, 12, source_size);
            var ds_bytes: [28]u8 = undefined;
            try readRequired(source, &ds_bytes);
            // 24..28 = table entry count; 12 = FourCC + 64-bit size per entry.
            const table_length = @as(u64, std.mem.readInt(u32, ds_bytes[24..28], .little)) * 12;
            if (table_length > ds_header.size - 28) return error.InvalidData;
            result.ds64 = .{
                .riff_size = std.mem.readInt(u64, ds_bytes[0..8], .little),
                .data_size = std.mem.readInt(u64, ds_bytes[8..16], .little),
                .sample_count = if (std.mem.eql(u8, &id, "RF64")) std.mem.readInt(u64, ds_bytes[16..24], .little) else null,
                .table = .{ .offset = 48, .length = table_length }, // 48 = payload offset 20 + fixed fields 28.
            };
            result.header.chunk.size = result.ds64.?.riff_size;
            result.offset = ds_chunk.next_offset;
            result.table_offset = 48;
        }
        if (result.header.chunk.size < 4) return error.InvalidData; // 4 = required form type.
        result.end = std.math.add(u64, result.header.chunk.size, 8) catch return error.InvalidData;
        if (result.end > source_size) return error.TruncatedData;
        if (result.offset > result.end) return error.InvalidData;
        return result;
    }

    /// Return the next chunk with resolved sizes, leaving source at its payload; null means EOF.
    pub fn next(self: *Iterator) Error!?Chunk {
        if (self.offset == self.end) return null;
        var header = try readHeader(self.source, self.offset, self.end, self.header.byteOrder());
        if (self.ds64 != null and std.mem.eql(u8, &header.id, "ds64")) return error.InvalidData;
        const is_data = std.mem.eql(u8, &header.id, "data");
        if (self.ds64) |ds64| {
            if (header.size == std.math.maxInt(u32)) {
                if (is_data and !self.seen_data) {
                    header.size = ds64.data_size;
                } else {
                    if (self.table_offset == try ds64.table.end()) return error.InvalidData;
                    try self.source.seekTo(self.table_offset);
                    var entry: [12]u8 = undefined;
                    try readRequired(self.source, &entry);
                    if (!std.mem.eql(u8, &header.id, entry[0..4])) return error.InvalidData;
                    header.size = std.mem.readInt(u64, entry[4..12], .little);
                    self.table_offset += 12;
                }
            }
        }
        const chunk = try frame(header, self.offset, self.end);
        try self.source.seekTo(chunk.data.offset);
        self.offset = chunk.next_offset;
        if (is_data) self.seen_data = true;
        return chunk;
    }
};
