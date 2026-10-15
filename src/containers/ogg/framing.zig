//! ogg framing derived from libogg 1.3.6.
//! pages and packets borrow storage; stream state owns allocations.
const std = @import("std");

pub const Error = std.mem.Allocator.Error
    || error{ InvalidData, InvalidState, Overflow, LimitExceeded };
// a page holds at most 255 segments of 255 bytes each.
pub const maxBodyBytes = 255 * 255;
// 27 fixed header bytes plus up to 255 laces.
pub const maxPageBytes = 27 + 255 + maxBodyBytes;
pub const Crc = std.hash.crc.Crc(
    u32,
    .{
        .polynomial = 0x04c11db7,
        .initial = 0,
        .reflect_input = false,
        .reflect_output = false,
        .xor_output = 0,
    },
);

/// borrow a structurally valid page; initialization checks layout only.
/// verify checksums separately or use the synchronizer.
pub const Page = struct {
    header: []const u8,
    body: []const u8,

    pub fn init(header: []const u8, body: []const u8) Error!Page {
        // header: signature (4), version (1), flags (1), granule (8),
        // serial (4), sequence (4), crc (4), segment count (1).
        if (header.len < 27 or !std.mem.eql(u8, header[0..4], "OggS"))
            return error.InvalidData;
        // byte 26 counts laces after the fixed header.
        if (header.len != 27 + @as(usize, header[26])) return error.InvalidData;
        var length: usize = 0;
        for (header[27..]) |segment| length += segment;
        if (body.len != length) return error.InvalidData;
        return .{ .header = header, .body = body };
    }
    pub fn version(self: Page) u8 {
        return self.header[4];
    }
    pub fn flags(self: Page) u8 {
        // bits 0/1/2 mark continuation, stream start, and stream end.
        return self.header[5];
    }
    pub fn isContinued(self: Page) bool {
        return self.flags() & 1 != 0;
    }
    pub fn isBeginning(self: Page) bool {
        return self.flags() & 2 != 0;
    }
    pub fn isEnd(self: Page) bool {
        return self.flags() & 4 != 0;
    }
    pub fn granulePosition(self: Page) i64 {
        // codec-defined end position; -1 means no packet completed.
        // multibyte header fields are little-endian.
        return std.mem.readInt(i64, self.header[6..14], .little);
    }
    pub fn serial(self: Page) u32 {
        // the serial identifies the logical stream.
        return std.mem.readInt(u32, self.header[14..18], .little);
    }
    pub fn sequence(self: Page) u32 {
        // page sequence numbers wrap at 32 bits.
        return std.mem.readInt(u32, self.header[18..22], .little);
    }
    pub fn segments(self: Page) []const u8 {
        return self.header[27..];
    }
    pub fn packetCount(self: Page) usize {
        var count: usize = 0;
        // 255 continues a packet; a smaller lace ends it.
        // exact multiples of 255 need a zero terminator.
        for (self.segments()) |segment| count += @intFromBool(segment < 255);
        return count;
    }
    /// calculate crc with a zero checksum field; leave input unchanged.
    pub fn checksum(self: Page) u32 {
        var crc = Crc.init();
        crc.update(self.header[0..22]);
        crc.update(&.{ 0, 0, 0, 0 });
        crc.update(self.header[26..]);
        crc.update(self.body);
        return crc.final();
    }
    pub fn verifyChecksum(self: Page) bool {
        return self.checksum() == std.mem.readInt(
                u32,
                self.header[22..26],
                .little,
            );
    }
    /// the mutable header must be this page's borrowed header.
    pub fn setChecksum(self: Page, header: []u8) Error!void {
        if (header.ptr != self.header.ptr or header.len != self.header.len)
            return error.InvalidData;
        std.mem.writeInt(u32, header[22..26], self.checksum(), .little);
    }
};

pub const Location = struct { offset: u64, sequence: u32, segment: u8 };
pub const Packet = struct {
    bytes: []const u8,
    beginning: bool = false,
    end: bool = false,
    granule: i64 = -1,
    number: i64 = 0,
    location: ?Location = null,
};

/// synchronize pages; report each gap once. views expire on buffer access,
/// reserve, reset, or cleanup, but survive page extraction.
pub const Sync = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8) = .empty,
    returned: usize = 0,
    unsynced: bool = false,
    headerBytes: usize = 0,
    bodyBytes: usize = 0,
    bounded: bool = false,
    committedCapacity: usize = 0,

    pub const SeekResult = union(enum) {
        needInput,
        skipped: usize,
        page: Page,
    };
    pub const Result = union(enum) { needInput, hole, page: Page };

    pub fn init(allocator: std.mem.Allocator) Sync {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Sync) void {
        self.data.deinit(self.allocator);
        self.data = .empty;
        self.reset();
    }
    pub fn reset(self: *Sync) void {
        self.data.clearRetainingCapacity();
        self.returned = 0;
        self.unsynced = false;
        self.headerBytes = 0;
        self.bodyBytes = 0;
        self.committedCapacity = 0;
    }
    pub fn reserve(self: *Sync, bytes: usize) Error!void {
        try self.data.ensureTotalCapacityPrecise(self.allocator, bytes);
    }
    /// borrow writable space; commit only the bytes filled.
    pub fn buffer(self: *Sync, size: usize) Error![]u8 {
        if (self.returned != 0) {
            const remaining = self.data.items[self.returned..];
            std.mem.copyForwards(
                u8,
                self.data.items[0..remaining.len],
                remaining,
            );
            self.data.items.len = remaining.len;
            self.returned = 0;
        }
        const needed = std.math.add(usize, self.data.items.len, size)
            catch return error.Overflow;
        if (needed > self.data.capacity) {
            if (self.bounded) return error.LimitExceeded;
            const capacity = std.math.add(usize, needed, 4096)
                catch return error.Overflow;
            try self.reserve(capacity);
        }
        self.committedCapacity = self.data.capacity - self.data.items.len;
        return self.data.unusedCapacitySlice();
    }
    pub fn commit(self: *Sync, size: usize) Error!void {
        if (size > self.committedCapacity) return error.InvalidState;
        self.data.items.len += size;
        self.committedCapacity -= size;
    }
    pub fn pageSeek(self: *Sync) SeekResult {
        const bytes = self.data.items[self.returned..];
        if (bytes.len < 27) return .needInput;
        if (self.headerBytes == 0 and std.mem.eql(u8, bytes[0..4], "OggS")) {
            const headerLength = 27 + @as(usize, bytes[26]);
            if (bytes.len < headerLength) return .needInput;
            self.headerBytes = headerLength;
            self.bodyBytes = 0;
            for (bytes[27..headerLength]) |segment| self.bodyBytes += segment;
        }
        if (self.headerBytes != 0) {
            const length = self.headerBytes + self.bodyBytes;
            if (bytes.len < length) return .needInput;
            const page = Page{
                .header = bytes[0..self.headerBytes],
                .body = bytes[self.headerBytes..length],
            };
            if (page.verifyChecksum()) {
                self.returned += length;
                self.unsynced = false;
                self.headerBytes = 0;
                self.bodyBytes = 0;
                return .{ .page = page };
            }
        }
        self.headerBytes = 0;
        self.bodyBytes = 0;
        const skip = if (std.mem.indexOfScalar(u8, bytes[1..], 'O')) |index|
            index + 1
        else
            bytes.len;
        self.returned += skip;
        return .{ .skipped = skip };
    }
    pub fn pageOut(self: *Sync) Result {
        while (true)
            switch (self.pageSeek()) {
                .needInput => return .needInput,
                .page => |page| return .{ .page = page },
                .skipped => {
                    if (!self.unsynced) {
                        self.unsynced = true;
                        return .hole;
                    }
                },
            };
    }
};

/// encode or decode one logical stream; use separate instances.
/// views expire on insertion, reserve, reset, or cleanup.
/// encoded headers also expire on the next page output.
pub const Stream = struct {
    const Lace = struct {
        value: u16,
        granule: i64 = -1,
        location: ?Location = null,
    };
    allocator: std.mem.Allocator,
    serial: u32,
    body: std.ArrayList(u8) = .empty,
    laces: std.ArrayList(Lace) = .empty,
    bodyReturned: usize = 0,
    laceReturned: usize = 0,
    completeLaces: usize = 0,
    nextSequence: ?u32 = 0,
    packetNumber: i64 = 0,
    granule: i64 = 0,
    beginning: bool = false,
    ended: bool = false,
    bounded: bool = false,
    maxPacketBytes: usize = std.math.maxInt(usize),
    header: [282]u8 = undefined,
    mode: enum { unset, encode, decode } = .unset,

    pub const Result = union(enum) { needInput, hole, packet: Packet };
    pub const PageOptions = struct {
        /// source offset for packet locations.
        offset: ?u64 = null,
        /// resume at a packet boundary after validating the full page.
        startSegment: u8 = 0,
        resuming: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, serial: u32) Error!Stream {
        var self = Stream{ .allocator = allocator, .serial = serial };
        errdefer self.deinit();
        try self.reserve(16 * 1024, 1024);
        return self;
    }
    pub fn deinit(self: *Stream) void {
        self.body.deinit(self.allocator);
        self.laces.deinit(self.allocator);
        self.body = .empty;
        self.laces = .empty;
        self.reset();
    }
    pub fn reserve(
        self: *Stream,
        bodyBytes: usize,
        segments: usize,
    ) Error!void {
        try self.body.ensureTotalCapacityPrecise(self.allocator, bodyBytes);
        try self.laces.ensureTotalCapacityPrecise(self.allocator, segments);
    }
    pub fn reset(self: *Stream) void {
        self.body.clearRetainingCapacity();
        self.laces.clearRetainingCapacity();
        self.bodyReturned = 0;
        self.laceReturned = 0;
        self.completeLaces = 0;
        self.nextSequence = null;
        self.packetNumber = 0;
        self.granule = 0;
        self.beginning = false;
        self.ended = false;
        self.mode = .unset;
    }
    pub fn resetSerial(self: *Stream, serial: u32) void {
        self.reset();
        self.serial = serial;
    }
    pub fn isEnd(self: *const Stream) bool {
        return self.ended;
    }
    pub fn hasPartialPacket(self: *const Stream) bool {
        return self.laces.items.len > self.completeLaces;
    }
    pub fn partialBytes(self: *const Stream) usize {
        var length: usize = 0;
        for (self.laces.items[self.completeLaces..]) |lace|
            length += lace.value & 255;
        return length;
    }
    fn compact(self: *Stream) void {
        if (self.bodyReturned != 0) {
            const remaining = self.body.items[self.bodyReturned..];
            std.mem.copyForwards(
                u8,
                self.body.items[0..remaining.len],
                remaining,
            );
            self.body.items.len = remaining.len;
            self.bodyReturned = 0;
        }
        if (self.laceReturned != 0) {
            const remaining = self.laces.items[self.laceReturned..];
            std.mem.copyForwards(
                Lace,
                self.laces.items[0..remaining.len],
                remaining,
            );
            self.laces.items.len = remaining.len;
            self.completeLaces -= self.laceReturned;
            self.laceReturned = 0;
        }
    }
    fn ensure(self: *Stream, bodyBytes: usize, segments: usize) Error!void {
        if (self.bounded) {
            if (
                bodyBytes > self.body.capacity
                    or segments > self.laces.capacity
            )
                return error.LimitExceeded;
        } else {
            try self.body.ensureTotalCapacity(self.allocator, bodyBytes);
            try self.laces.ensureTotalCapacity(self.allocator, segments);
        }
    }
    /// copy a packet; input must not alias stream storage.
    pub fn packetIn(self: *Stream, packet: Packet) Error!void {
        try self.slicesIn(&.{packet.bytes}, packet.end, packet.granule);
    }
    /// copy packet slices; input must not alias stream storage.
    pub fn slicesIn(
        self: *Stream,
        slices: []const []const u8,
        end: bool,
        granule: i64,
    ) Error!void {
        if (self.mode == .decode) return error.InvalidState;
        var bytes: usize = 0;
        for (slices) |slice|
            bytes = std.math.add(usize, bytes, slice.len)
                catch return error.Overflow;
        if (bytes > self.maxPacketBytes) return error.LimitExceeded;
        const segments = bytes / 255 + 1;
        self.compact();
        const bodyLength = std.math.add(usize, self.body.items.len, bytes)
            catch return error.Overflow;
        const laceLength = std.math.add(usize, self.laces.items.len, segments)
            catch return error.Overflow;
        const number = std.math.add(i64, self.packetNumber, 1)
            catch return error.Overflow;
        try self.ensure(bodyLength, laceLength);
        self.mode = .encode;
        for (slices) |slice| self.body.appendSliceAssumeCapacity(slice);
        for (0..segments) |index|
            self.laces.appendAssumeCapacity(
                .{
                    .value = (if (index + 1 == segments)
                        @as(u16, @intCast(bytes % 255))
                    else
                        255)
                        | (if (index == 0) @as(u16, 0x100) else 0),
                    .granule = if (index + 1 == segments)
                        granule
                    else
                        self.granule,
                },
            );
        self.granule = granule;
        self.packetNumber = number;
        self.ended = self.ended or end;
    }
    /// check layout here; verify checksums before insertion.
    pub fn pageIn(
        self: *Stream,
        incoming: Page,
        options: PageOptions,
    ) Error!void {
        if (self.mode == .encode) return error.InvalidState;
        const page = try Page.init(incoming.header, incoming.body);
        if (page.serial() != self.serial or page.version() != 0)
            return error.InvalidData;
        if (options.startSegment > page.segments().len)
            return error.InvalidData;
        if (options.startSegment != 0 and !options.resuming)
            return error.InvalidState;
        self.compact();
        errdefer self.reset();
        // allocate before changing queues so failures remain resettable.
        const bodyLength = std.math.add(
            usize,
            self.body.items.len,
            page.body.len,
        )
            catch return error.Overflow;
        const laceLength = std.math.add(
            usize,
            self.laces.items.len,
            page.segments().len + 1,
        )
            catch return error.Overflow;
        try self.ensure(bodyLength, laceLength);
        self.mode = .decode;
        if (
            self.nextSequence == null
                or page.sequence() != self.nextSequence.?
        ) {
            // discard unfinished packets after a gap and queue a hole marker.
            const partial = self.partialBytes();
            self.body.items.len -= partial;
            self.laces.items.len = self.completeLaces;
            if (self.nextSequence != null) {
                self.laces.appendAssumeCapacity(.{ .value = 0x400 });
                self.completeLaces += 1;
            }
        }
        var segment: usize = options.startSegment;
        var cursor: usize = 0;
        for (page.segments()[0..segment]) |length| cursor += length;
        var bos = page.isBeginning();
        if (
            !options.resuming
                and page.isContinued()
                and !self.hasPartialPacket()
        ) {
            // skip an incomplete packet's tail through its terminating lace.
            bos = false;
            while (segment < page.segments().len) {
                const length = page.segments()[segment];
                cursor += length;
                segment += 1;
                if (length < 255) break;
            }
        }
        var partial = self.partialBytes();
        var saved: ?usize = null;
        for (page.segments()[segment..], segment..) |length, index| {
            partial = std.math.add(usize, partial, length)
                catch return error.Overflow;
            if (partial > self.maxPacketBytes) return error.LimitExceeded;
            const start = !self.hasPartialPacket();
            self.body.appendSliceAssumeCapacity(page.body[cursor..][0..length]);
            cursor += length;
            self.laces.appendAssumeCapacity(
                .{
                    .value = @as(u16, length)
                        | (if (bos) @as(u16, 0x100) else 0),
                    .location = if (start and options.offset != null) .{
                        .offset = options.offset.?,
                        .sequence = page.sequence(),
                        .segment = @intCast(index),
                    } else null,
                },
            );
            bos = false;
            if (length < 255) {
                saved = self.laces.items.len - 1;
                self.completeLaces = self.laces.items.len;
                partial = 0;
            }
        }
        // only the last completed packet receives the page granule.
        if (saved) |index|
            self.laces.items[index].granule = page.granulePosition();
        if (page.isEnd()) {
            self.ended = true;
            if (self.laces.items.len != 0)
                self.laces.items[self.laces.items.len - 1].value |= 0x200;
        }
        self.nextSequence = page.sequence() +% 1;
    }
    /// peeking consumes hole markers but leaves packets queued.
    pub fn packetPeek(self: *Stream) Result {
        return self.extract(false);
    }
    pub fn packetOut(self: *Stream) Result {
        return self.extract(true);
    }
    /// borrow one packet; advance consumes it. peeking also consumes holes.
    fn extract(self: *Stream, advance: bool) Result {
        // wait for a complete packet; trailing fragments need another page.
        if (self.mode != .decode or self.laceReturned >= self.completeLaces)
            return .needInput;
        const first = self.laces.items[self.laceReturned];
        // 0x400 marks missing pages; consume the marker even when peeking.
        if (first.value & 0x400 != 0) {
            self.laceReturned += 1;
            self.packetNumber +%= 1;
            return .hole;
        }
        var index = self.laceReturned;
        var bytes: usize = 0;
        var end = false;
        // sum lace lengths: 255 continues a packet, anything smaller ends it.
        while (true) : (index += 1) {
            const lace = self.laces.items[index];
            bytes += lace.value & 255;
            // 0x200 marks end of stream.
            end = end or lace.value & 0x200 != 0;
            if (lace.value & 255 < 255) break;
        }
        // assembled packet bytes are contiguous; borrow them without copying.
        const packet = Packet{
            .bytes = self.body.items[self.bodyReturned..][0..bytes],
            // 0x100 marks the first packet in decode mode.
            .beginning = first.value & 0x100 != 0,
            .end = end,
            // only the last packet completed on a page gets its granule.
            .granule = self.laces.items[index].granule,
            .number = self.packetNumber,
            // retain the packet start for seeking.
            .location = first.location,
        };
        if (advance) {
            // consume bytes and laces; peeking leaves both cursors unchanged.
            self.bodyReturned += bytes;
            self.laceReturned = index + 1;
            self.packetNumber +%= 1;
        }
        return .{ .packet = packet };
    }
    pub fn pageOut(self: *Stream) ?Page {
        return self.pageOutFill(4096);
    }
    pub fn pageOutFill(self: *Stream, fill: usize) ?Page {
        return self.output(self.ended or !self.beginning, fill);
    }
    pub fn flush(self: *Stream) ?Page {
        return self.flushFill(4096);
    }
    pub fn flushFill(self: *Stream, fill: usize) ?Page {
        return self.output(true, fill);
    }
    /// build one borrowed ogg page, or wait. fill is a target; force allows
    /// less.
    fn output(self: *Stream, force: bool, fill: usize) ?Page {
        if (self.mode != .encode or self.laces.items.len == 0) return null;
        // at most 255 laces per page.
        const maximum = @min(self.laces.items.len, 255);
        var count: usize = 0;
        // -1 means no packet finishes on this page.
        var granule: i64 = -1;
        var forced = force;
        if (!self.beginning) {
            // first page: take the first packet, up to the lace limit.
            // beginning becomes true after emission.
            granule = 0;
            while (count < maximum) {
                const value = self.laces.items[count].value & 255;
                count += 1;
                if (value < 255) break;
            }
        } else {
            var accumulated: usize = 0;
            var packets: usize = 0;
            var justCompleted: usize = 0;
            while (count < maximum) : (count += 1) {
                // prefer a packet boundary past fill with at least four
                // packets.
                if (accumulated > fill and justCompleted >= 4) {
                    forced = true;
                    break;
                }
                const lace = self.laces.items[count];
                accumulated += lace.value & 255;
                // only completed packets qualify as stopping points.
                if (lace.value & 255 < 255) {
                    granule = lace.granule;
                    packets += 1;
                    justCompleted = packets;
                } else justCompleted = 0;
            }
            // a full lace table forces output, even mid-packet.
            if (count == 255) forced = true;
        }
        // keep queued data until ready or forced.
        if (!forced) return null;
        // 27 fixed bytes, then one byte per lace.
        const header = self.header[0..27 + count];
        @memcpy(header[0..4], "OggS");
        header[4] = 0; // ogg version.
        // flags: continuation (1), stream start (2), stream end (4).
        // no 0x100 means continuation; only the final page marks stream end.
        header[5] = @as(
            u8,
            if (self.laces.items[0].value & 0x100 == 0) 1 else 0,
        )
            | @as(u8, if (!self.beginning) 2 else 0)
            | @as(
                u8,
                if (self.ended and count == self.laces.items.len) 4 else 0,
            );
        // little-endian: granule (6..14), serial (14..18), sequence (18..22).
        std.mem.writeInt(i64, header[6..14], granule, .little);
        std.mem.writeInt(u32, header[14..18], self.serial, .little);
        const sequence = self.nextSequence orelse 0;
        std.mem.writeInt(u32, header[18..22], sequence, .little);
        self.nextSequence = sequence +% 1;
        // zero crc (22..26) for calculation; byte 26 counts laces.
        @memset(header[22..26], 0);
        header[26] = @intCast(count);
        var length: usize = 0;
        for (self.laces.items[0..count], 0..) |lace, index| {
            // store lengths only; discard internal flags.
            header[27 + index] = @truncate(lace.value);
            length += lace.value & 255;
        }
        // borrow the body and checksum header, laces, and body.
        const page = Page{
            .header = header,
            .body = self.body.items[self.bodyReturned..][0..length],
        };
        std.mem.writeInt(u32, header[22..26], page.checksum(), .little);
        // remove laces; leave borrowed body bytes in place until compaction.
        const remaining = self.laces.items[count..];
        std.mem.copyForwards(
            Lace,
            self.laces.items[0..remaining.len],
            remaining,
        );
        self.laces.items.len = remaining.len;
        self.bodyReturned += length;
        self.beginning = true;
        return page;
    }
};
