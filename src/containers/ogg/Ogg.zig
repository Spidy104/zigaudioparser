//! Ogg container reader: page validation, packet reconstruction, and seeking.
//! Currently supports Opus; its header and timing rules live in this reader.
//! Audio decoding is implemented separately in codecs/opus.zig.
//! Supports a single logical stream with channel mapping family 0 or 1.
//! All decoded positions and durations use 48 kHz samples per channel.
// Encapsulation: https://www.rfc-editor.org/rfc/rfc7845.html
const std = @import("std");
const types = @import("../../types.zig");
const Source = @import("../../Source.zig");
const PacketSource = @import("../../PacketSource.zig");
const SeekIndex = @import("../seek_index.zig").Index(Pages.Location);
const VorbisComments = @import("../VorbisComments.zig");
const Error = types.Error;
const Self = @This();
allocator: std.mem.Allocator,
pages: Pages,
options: types.Options,
config: types.OpusConfig = .{},
metadata: types.Info = undefined,
/// Decoded interval retained after applying pre-skip and final granule
/// trimming.
presentation: types.Presentation = .{},
/// Granule position immediately before the first decoded audio sample.
origin: u64 = 0,
/// Absolute untrimmed position of the next audio packet, on the granule
/// timeline.
frame: u64 = 0,
/// Untrimmed decoded positions paired with Ogg packet locations.
index: SeekIndex = .{},
/// Sample counts for the current page's audio packets, indexed like
/// pages.packets.
durations: [255]u16 = undefined,
headers: u8 = 0,
first_audio: bool = true,
/// Emit final presentation bounds before returning audio from the EOS page.
bounds_pending: bool = false,
configured: bool = false,
seekable: bool = false,

/// Open borrowed input after its first four bytes have been consumed as prefix.
/// Read both headers and the first audio page; scan/index the rest when
/// seekable
/// with known size, then resume at the first audio packet. The returned source
/// owns packet/index storage. Keep input unchanged; position is unspecified on
/// error.
/// Allocates state, fixed Ogg assembly buffers, and any seek index here. Audio
/// packets and tags must fit options.bufferCapacity();
pub fn init(
    allocator: std.mem.Allocator,
    source: Source,
    prefix: [4]u8,
    options: types.Options,
) Error!PacketSource {
    if (!@import("codec_options").opus) return error.UnsupportedEncoding;
    const self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .pages = .{
            .allocator = allocator,
            .input = .{ .source = source, .prefix = prefix },
            .limit = options.max_payload_bytes,
        },
        .options = options,
    };
    errdefer self.deinit();
    try self.pages.initBuffers(options.bufferCapacity());
    self.seekable = source.seek_to != null and try source.getSize() != null;
    if (!try self.loadAudioPage()) return error.InvalidData;
    if (self.seekable) {
        while (true) {
            while (self.pages.nextPacket()) |packet| {
                try self.index.append(
                    allocator,
                    options.max_index_bytes,
                    .{ .frame = self.frame, .location = packet.location },
                );
                self.frame = std.math.add(
                    u64,
                    self.frame,
                    self.durations[packet.index],
                )
                    catch return error.InvalidData;
            }
            if (!try self.loadAudioPage()) break;
        }
        self.metadata.total_frames = self.frame - self.origin;
        _ = try seek(self, self.origin);
    }
    return .{
        .backend = .{ .ogg = self },
        .encoding = .{ .opus = self.config },
        .format = .{ .sample_rate = 48000, .channels = self.metadata.channels },
        .presentation = self.presentation,
        .decoded_origin = std.math.cast(i64, self.origin)
            orelse return error.InvalidData,
        .seekable = self.seekable,
        .max_payload_bytes = options.max_payload_bytes,
    };
}
/// Validate OpusHead and copy channel mapping, pre-skip, and signed Q7.8 dB
/// gain.
fn parseOpusHead(self: *Self, packet_bytes: []const u8) Error!void {
    // The fixed OpusHead is 19 bytes: signature (8), version (1), channels (1),
    // pre-skip (2), input rate (4), output gain (2), and mapping family (1).
    if (
        packet_bytes.len < 19
            or !std.mem.eql(u8, packet_bytes[0..8], "OpusHead")
    ) {
        return error.UnsupportedEncoding;
    }
    // Versions 1..15 share the current major version (the upper four bits).
    if (packet_bytes[8] == 0 or packet_bytes[8] > 15) {
        return error.UnsupportedEncoding;
    }
    const channels = packet_bytes[9];
    if (channels == 0) return error.InvalidData;
    if (channels > 8) return error.UnsupportedEncoding;
    self.metadata = .{
        .format = .ogg,
        .sample_rate = 48000,
        .channels = channels,
        .total_frames = null,
    };
    // Bytes 10..12 hold pre-skip. The original input rate at 12..16 is
    // informational: decoding and granule arithmetic here always use 48 kHz.
    self.presentation.start = std.mem.readInt(
        u16,
        packet_bytes[10..12],
        .little,
    );
    self.config.gain_q8 = std.mem.readInt(i16, packet_bytes[16..18], .little);
    // Family 0 implies one mono/stereo stream; family 1 carries an explicit
    // map.
    switch (packet_bytes[18]) {
        0 => {
            if (
                channels > 2
                    or (packet_bytes[8] == 1 and packet_bytes.len != 19)
            ) {
                return error.InvalidData;
            }
            self.config.coupled_streams = channels - 1;
        },
        1 => {
            // Family 1 adds stream/coupled counts at 19/20, then one map byte
            // per output channel starting at byte 21.
            if (packet_bytes.len < 21 + @as(usize, channels)) {
                return error.InvalidData;
            }
            if (
                packet_bytes[8] == 1
                    and packet_bytes.len != 21 + @as(usize, channels)
            ) {
                return error.InvalidData;
            }
            self.config.streams = packet_bytes[19];
            self.config.coupled_streams = packet_bytes[20];
            if (
                packet_bytes[19] == 0
                    or packet_bytes[20] > packet_bytes[19]
                    or @as(u16, packet_bytes[19]) + packet_bytes[20] > 255
            ) {
                return error.InvalidData;
            }
            @memcpy(
                self.config.mapping[0..channels],
                packet_bytes[21..][0..channels],
            );
            // Mapping value 255 requests silence rather than a coded channel.
            for (self.config.mapping[0..channels]) |channel_index| {
                if (
                    channel_index != 255
                        and channel_index >= @as(u16, packet_bytes[19])
                                + packet_bytes[20]
                ) {
                    return error.InvalidData;
                }
            }
        },
        else => return error.UnsupportedEncoding,
    }
}
/// Validate length-prefixed vendor/comment fields without retaining descriptive
/// tags.
/// Any remaining comment-packet padding is accepted.
fn parseOpusTags(packet_bytes: []const u8) Error!void {
    if (!std.mem.startsWith(u8, packet_bytes, "OpusTags")) {
        return error.InvalidData;
    }
    var comments = try VorbisComments.init(packet_bytes[8..]);
    while (try comments.next()) |_| {}
}
/// Read the first elementary stream's TOC duration, in 48 kHz samples per
/// channel.
/// Multistream packets require equal durations in every stream; the codec
/// validates
/// the complete payload. This helper checks only TOC framing and the 120 ms
/// limit.
fn opusDuration(packet_bytes: []const u8) Error!u16 {
    if (packet_bytes.len == 0) return error.InvalidData;
    const toc = packet_bytes[0];
    // TOC bit 7 selects CELT-only: 120 << n samples = 2.5/5/10/20 ms.
    // Otherwise bits 6..5 == 11 select hybrid: 480/960 = 10/20 ms.
    // SILK-only uses 480/960/1920/2880 = 10/20/40/60 ms, all at 48 kHz.
    const samples_per_frame: u16 = if (toc & 128 != 0)
        @as(u16, 120) << @as(u2, @truncate(toc >> 3))
    else if (toc & 0x60 == 0x60)
        (if (toc & 8 != 0) @as(u16, 960) else 480)
    else
        switch ((toc >> 3) & 3) {
            0 => 480,
            1 => 960,
            2 => 1920,
            else => 2880,
        };
    // The low two TOC bits encode one frame, two frames, or a count stored
    // in the next byte's low six bits (mask 63); its upper bits are flags.
    const frame_count: u16 = switch (toc & 3) {
        0 => 1,
        1, 2 => 2,
        else => if (packet_bytes.len < 2)
            return error.InvalidData
        else
            packet_bytes[1] & 63,
    };
    const packet_samples: u32 = @as(u32, samples_per_frame) * frame_count;
    // An Opus packet may contain at most 120 ms: 5760 samples at 48 kHz.
    if (frame_count == 0 or packet_samples > 5760) return error.InvalidData;
    return @intCast(packet_samples);
}
/// Gather an audio-bearing page and establish its untrimmed sample positions.
/// Whole-page packet durations are needed because its granule describes the
/// final
/// completed packet, and EOS may trim samples from that page before
/// presentation.
fn loadAudioPage(self: *Self) Error!bool {
    while (try self.pages.nextPage()) {
        while (self.headers < 2 and self.pages.hasPacket()) {
            const packet = self.pages.nextPacket().?;
            if (self.headers == 0) {
                // OpusHead must be alone on the beginning-of-stream page (flag
                // 2).
                if (
                    self.pages.flags != 2
                        or self.pages.count != 1
                        or self.pages.partial.items.len != 0
                        or self.pages.granule != 0
                ) {
                    return error.InvalidData;
                }
                try self.parseOpusHead(packet.bytes);
            } else {
                try parseOpusTags(packet.bytes);
                // OpusTags must finish its page, with no following packet data.
                if (
                    self.pages.hasPacket()
                        or self.pages.partial.items.len != 0
                        or self.pages.granule != 0
                ) {
                    return error.InvalidData;
                }
                // A stream joined mid-broadcast may start audio with a packet
                // fragment. Discard it before establishing the granule origin.
                self.pages.allow_missing_packet_start = true;
            }
            self.headers += 1;
        }
        if (!self.pages.hasPacket()) {
            if (
                self.pages.ended
                    or (self.pages.count != 0 and self.pages.granule != 0)
            ) {
                return error.InvalidData;
            }
            continue;
        }
        var page_samples: u64 = 0;
        for (self.pages.packet_cursor..self.pages.count) |packet_index| {
            self.durations[packet_index] = try opusDuration(
                self.pages.bytes(packet_index),
            );
            page_samples += self.durations[packet_index];
        }
        const granule: u64 = @intCast(self.pages.granule);
        if (self.first_audio) {
            // A nonzero initial granule origin is valid for cropped streams.
            self.origin = if (granule >= page_samples)
                granule - page_samples
            else if (self.pages.ended)
                0
            else
                return error.InvalidData;
            self.frame = self.origin;
            self.first_audio = false;
            // Presentation is relative to the logical stream's granule origin.
            self.presentation.start = std.math.add(
                u64,
                self.origin,
                self.presentation.start,
            )
                catch return error.InvalidData;
        }
        const page_end = std.math.add(u64, self.frame, page_samples)
            catch return error.InvalidData;
        if (self.pages.ended) {
            if (
                granule > page_end
                    or granule < self.frame
                    or granule < self.presentation.start
            ) {
                return error.InvalidData;
            }
            if (self.presentation.end) |expected| {
                if (granule != expected) return error.InvalidData;
            }
            self.presentation.end = granule;
            self.bounds_pending = true;
            self.metadata.total_frames = page_end - self.origin;
        } else if (granule != page_end) return error.InvalidData;
        return true;
    }
    return false;
}
/// Accept packet framing once; Ogg has already reconstructed packet boundaries.
pub fn configure(self: *Self, scheme: types.InputScheme) Error!void {
    if (self.configured) return error.InvalidState;
    if (scheme != .packets) return error.UnsupportedEncoding;
    self.configured = true;
}
/// Emit pending trim bounds, a borrowed audio packet, or stable end of input.
/// Packet bytes remain valid until the next advancing source operation.
pub fn next(self: *Self) Error!PacketSource.Event {
    if (!self.configured) return error.InvalidState;
    if (!self.pages.hasPacket()) {
        if (!try self.loadAudioPage()) {
            return .end;
        }
    }
    if (self.bounds_pending) {
        self.bounds_pending = false;
        return .{ .presentation = self.presentation };
    }
    const packet = self.pages.nextPacket().?;
    const frame = self.frame;
    self.frame = std.math.add(u64, frame, self.durations[packet.index])
        catch return error.InvalidData;
    return .{
        .packet = .{
            .bytes = packet.bytes,
            .duration = self.durations[packet.index],
            .timestamp = .{
                .value = std.math.cast(i64, frame)
                    orelse return error.InvalidData,
                .time_base = .{ .numerator = 1, .denominator = 48000 },
            },
        },
    };
}
/// Return metadata with raw decoded counts; Decoder exposes the trimmed count.
pub fn info(self: *const Self) types.Info {
    return self.metadata;
}
/// Resume at the indexed packet at/before target, or the first packet for
/// earlier targets.
/// The target is an untrimmed granule position with codec preroll already
/// subtracted;
/// Decoder resets the codec and discards history before exposing the requested
/// frame.
pub fn seek(self: *Self, target: u64) Error!PacketSource.SeekResult {
    if (!self.seekable) return error.Unseekable;
    const entry = self.index.atOrBefore(target)
        orelse return error.InvalidState;
    try self.pages.seek(entry.location);
    self.frame = entry.frame;
    self.bounds_pending = false;
    return .{
        .frame = std.math.cast(i64, entry.frame)
            orelse return error.InvalidData,
    };
}
/// Free packet/index storage and source state; leave borrowed input open.
pub fn deinit(self: *Self) void {
    self.pages.deinit();
    self.index.deinit(self.allocator);
    const allocator = self.allocator;
    allocator.destroy(self);
}

/// Ogg version 0 page framing for one logical stream. Chaining and multiplexing
/// are rejected; codec-specific timing is handled by the enclosing reader.
// Page format: https://www.rfc-editor.org/rfc/rfc3533.html#section-6
const Pages = struct {
    /// Where an encoded packet begins
    pub const Location = struct {
        /// Absolute byte offset of the page's OggS capture pattern.
        offset: u64,
        /// Page sequence number used to resume continuity checks after seeking.
        sequence: u32,
        /// Index of the packet's first lacing entry within that page.
        segment: u8,
    };
    /// Completed packet: begin..end indexes data; location identifies its
    /// source start.
    /// Both this descriptor and the associated bytes are invalidated by
    /// nextPage/seek.
    pub const Packet = struct { begin: usize, end: usize, location: Location };
    /// Packet borrowed by nextPacket(); index identifies its slot on the
    /// current page.
    pub const PacketView = struct {
        bytes: []const u8,
        location: Location,
        index: usize,
    };
    allocator: std.mem.Allocator,
    input: Input,
    /// Maximum assembled packet size, including packets that span pages.
    limit: usize,
    serial: ?u32 = null,
    sequence: u32 = 0,
    ended: bool = false,
    finished: bool = false,
    resuming: bool = false,
    skip_segments: usize = 0,
    /// Permit a missing packet beginning on the next page only. The container
    /// reader enables this at a supported stream-joining boundary, after its
    /// headers.
    allow_missing_packet_start: bool = false,
    /// Discard laces and payload until the incomplete packet ends, even across
    /// pages.
    discarding_packet: bool = false,
    // Maximum page: fixed header (27) + lacing table (255) + body (255 * 255).
    page: [65307]u8 = undefined,
    /// Concatenated packets completed on the current page. Capacity is reserved
    /// by
    /// initBuffers; nextPage copies packets here.
    data: std.ArrayList(u8) = .empty,
    /// Packet assembly storage, including packets spanning pages. Fixed
    /// capacity.
    partial: std.ArrayList(u8) = .empty,
    partial_location: Location = undefined,
    packets: [255]Packet = undefined,
    /// Number of valid entries in packets; a page may complete no packets.
    count: usize = 0,
    /// Next packet to expose on this page; nextPage and seek reset the cursor.
    packet_cursor: usize = 0,
    /// Codec-defined position of the last completed packet; -1 means none
    /// completed.
    granule: i64 = -1,
    /// Wire flags: 0x01 continuation, 0x02 beginning, 0x04 end of logical
    /// stream.
    flags: u8 = 0,

    /// Allocate packet assembly storage once, before reading pages. In addition
    /// to
    /// the inline page buffer, reserve capacity bytes for a partial packet and
    /// capacity + 65025 bytes for completed packets (a continued packet plus a
    /// page).
    /// The caller must deinit this reader on initialization failure as well.
    pub fn initBuffers(self: *Pages, capacity: usize) Error!void {
        if (self.partial.capacity != 0 or self.data.capacity != 0) {
            return error.InvalidState;
        }
        const packet_capacity = @min(capacity, self.limit);
        if (packet_capacity == 0) return error.LimitExceeded;
        const page_capacity = std.math.add(usize, packet_capacity, 255 * 255)
            catch return error.LimitExceeded;
        try self.partial.ensureTotalCapacityPrecise(
            self.allocator,
            packet_capacity,
        );
        try self.data.ensureTotalCapacityPrecise(self.allocator, page_capacity);
    }

    /// Read and validate a page, exposing completed packets through count and
    /// bytes().
    /// Leaves input just after the page body; true can mean zero completed
    /// packets.
    /// False requires physical EOF after EOS. Missing EOS or an unfinished
    /// final
    /// packet is TruncatedData. Any call invalidates previously borrowed packet
    /// bytes.
    pub fn nextPage(self: *Pages) Error!bool {
        if (self.finished) return false;
        self.data.clearRetainingCapacity();
        self.count = 0;
        self.packet_cursor = 0;
        const offset = self.input.position;
        if (self.ended) {
            var trailing: [1]u8 = undefined;
            if (try self.input.read(&trailing) != 0) {
                return error.UnsupportedChunkLayout;
            }
            self.finished = true;
            return false;
        }
        // 27 = fixed header length; byte 26 gives the following lacing-table
        // length.
        const header_bytes_read = try self.input.read(self.page[0..27]);
        // A logical stream must have EOS.
        if (header_bytes_read == 0) return error.TruncatedData;
        if (header_bytes_read != 27) return error.TruncatedData;
        // Byte 4 is the format version; only the low three flag bits are
        // defined.
        if (
            !std.mem.eql(u8, self.page[0..4], "OggS")
                or self.page[4] != 0
                or self.page[5] & ~@as(u8, 7) != 0
        ) {
            return error.InvalidData;
        }
        self.flags = self.page[5];
        self.granule = std.mem.readInt(i64, self.page[6..14], .little);
        const serial = std.mem.readInt(u32, self.page[14..18], .little);
        const sequence = std.mem.readInt(u32, self.page[18..22], .little);
        if (self.serial) |expected| {
            if (serial != expected or self.flags & 2 != 0) {
                return error.UnsupportedChunkLayout;
            }
            if (sequence != self.sequence) return error.InvalidData;
        } else {
            if (self.flags & 2 == 0 or self.flags & 1 != 0 or sequence != 0) {
                return error.InvalidData;
            }
            self.serial = serial;
        }
        self.sequence = sequence +% 1;
        const segment_count: usize = self.page[26];
        try self.input.required(self.page[27..][0..segment_count]);
        var body_length: usize = 0;
        for (self.page[27..][0..segment_count]) |segment_length| {
            body_length += segment_length;
        }
        const page_end = 27 + segment_count + body_length;
        try self.input.required(self.page[27 + segment_count..page_end]);
        // The checksum covers header, lacing, and body with bytes 22..26
        // zeroed.
        const expected_crc = std.mem.readInt(u32, self.page[22..26], .little);
        @memset(self.page[22..26], 0);
        if (crc(self.page[0..page_end]) != expected_crc) {
            return error.InvalidData;
        }
        if (!self.resuming) {
            if (
                self.allow_missing_packet_start
                    and self.partial.items.len == 0
                    and self.flags & 1 != 0
            ) {
                self.discarding_packet = true;
            }
            if (
                (self.flags & 1 != 0) != (self.partial.items.len != 0
                        or self.discarding_packet)
            ) {
                return error.InvalidData;
            }
        }
        self.allow_missing_packet_start = false;
        if (self.skip_segments > segment_count) return error.InvalidData;
        var cursor: usize = 27 + segment_count;
        for (
            self.page[27..][0..segment_count],
            0..,
        ) |segment_length, segment_index| {
            if (segment_index < self.skip_segments) {
                cursor += segment_length;
                continue;
            }
            if (self.discarding_packet) {
                cursor += segment_length;
                // As with packet assembly, a lace below 255 terminates the
                // packet.
                if (segment_length < 255) self.discarding_packet = false;
                continue;
            }
            if (self.partial.items.len == 0)
                self.partial_location = .{
                    .offset = offset,
                    .sequence = sequence,
                    .segment = @intCast(segment_index),
                };
            if (
                @as(usize, segment_length)
                    > self.limit -| self.partial.items.len
            ) {
                return error.LimitExceeded;
            }
            if (
                segment_length
                    > self.partial.capacity - self.partial.items.len
            ) {
                return error.LimitExceeded;
            }
            self.partial.appendSliceAssumeCapacity(
                self.page[cursor..][0..segment_length],
            );
            cursor += segment_length;
            // A lacing value of 255 continues a packet; a smaller value ends
            // it.
            // Exact multiples of 255 therefore need a final zero-length
            // segment.
            if (segment_length < 255) {
                const begin = self.data.items.len;
                if (
                    self.partial.items.len
                        > self.data.capacity - self.data.items.len
                ) {
                    return error.LimitExceeded;
                }
                self.data.appendSliceAssumeCapacity(self.partial.items);
                self.packets[self.count] = .{
                    .begin = begin,
                    .end = self.data.items.len,
                    .location = self.partial_location,
                };
                self.count += 1;
                self.partial.clearRetainingCapacity();
            }
        }
        self.skip_segments = 0;
        self.resuming = false;
        self.ended = self.flags & 4 != 0;
        if (
            self.ended
                and (self.partial.items.len != 0 or self.discarding_packet)
        ) {
            return error.TruncatedData;
        }
        // Granule validity describes the whole page, including discarded
        // fragments
        // and packets skipped on seek, rather than just the packets exposed to
        // callers.
        var completed_packets: usize = 0;
        for (self.page[27..][0..segment_count]) |segment_length| {
            if (segment_length < 255) completed_packets += 1;
        }
        if (completed_packets == 0 and self.granule != -1) {
            return error.InvalidData;
        }
        if (completed_packets != 0 and self.granule < 0) {
            return error.InvalidData;
        }
        return true;
    }
    /// Whether another completed packet is available on the current page.
    pub fn hasPacket(self: *const Pages) bool {
        return self.packet_cursor < self.count;
    }
    /// Borrow the next packet on this page without reading input.
    /// Null marks a page boundary; call nextPage explicitly so the container
    /// can inspect
    /// granules/flags and establish timing before consuming that page's
    /// packets.
    /// Advancing within a page preserves previous views; nextPage/seek
    /// invalidates them.
    pub fn nextPacket(self: *Pages) ?PacketView {
        if (!self.hasPacket()) return null;
        const packet_index = self.packet_cursor;
        self.packet_cursor += 1;
        return .{
            .bytes = self.bytes(packet_index),
            .location = self.packets[packet_index].location,
            .index = packet_index,
        };
    }
    /// Borrow a packet from the current page; packet_index must be less than
    /// count.
    pub fn bytes(self: *Pages, packet_index: usize) []const u8 {
        const packet = self.packets[packet_index];
        return self.data.items[packet.begin..packet.end];
    }
    /// Resume at a packet start returned by this reader, preserving its stream
    /// serial.
    /// Discard pending bytes; nextPage validates the full page but skips
    /// earlier laces.
    /// Input must be unchanged, and the location must belong to the same
    /// logical stream.
    pub fn seek(self: *Pages, location: Location) Error!void {
        try self.input.seek(location.offset);
        self.sequence = location.sequence;
        self.skip_segments = location.segment;
        self.resuming = true;
        self.ended = false;
        self.finished = false;
        self.allow_missing_packet_start = false;
        self.discarding_packet = false;
        self.partial.clearRetainingCapacity();
        self.data.clearRetainingCapacity();
        self.count = 0;
        self.packet_cursor = 0;
    }
    /// Free packet storage without closing the borrowed input.
    pub fn deinit(self: *Pages) void {
        self.data.deinit(self.allocator);
        self.partial.deinit(self.allocator);
    }
    // Ogg uses the non-reflected CRC-32 polynomial 0x04c11db7.
    const OggCrc = std.hash.crc.Crc(
        u32,
        .{
            .polynomial = 0x04c11db7,
            .initial = 0,
            .reflect_input = false,
            .reflect_output = false,
            .xor_output = 0,
        },
    );
    /// Compute the Ogg CRC with initial value zero and no final XOR.
    /// For a serialized page, the caller must first zero its checksum field.
    pub fn crc(page_bytes: []const u8) u32 {
        return OggCrc.hash(page_bytes);
    }

    /// Replay the detection prefix and track byte offsets in the borrowed Ogg
    /// input.
    const Input = struct {
        source: Source,
        /// Initial bytes already consumed by format detection; replayed before
        /// source.
        prefix: [4]u8,
        prefix_pos: usize = 0,
        /// Logical byte offset including the replayed prefix, relative to input
        /// start.
        position: u64 = 0,

        /// Fill out from prefix then source; a short count means EOF. Advance
        /// position.
        pub fn read(self: *Input, out: []u8) Error!usize {
            var bytes_read: usize = 0;
            if (self.prefix_pos < 4) {
                bytes_read = @min(out.len, 4 - self.prefix_pos);
                @memcpy(
                    out[0..bytes_read],
                    self.prefix[self.prefix_pos..][0..bytes_read],
                );
                self.prefix_pos += bytes_read;
            }
            bytes_read += try self.source.reader.readSliceShort(
                out[bytes_read..],
            );
            self.position = std.math.add(u64, self.position, bytes_read)
                catch return error.InvalidData;
            return bytes_read;
        }
        /// Fill out completely or return TruncatedData on premature EOF.
        pub fn required(self: *Input, out: []u8) Error!void {
            if (try self.read(out) != out.len) return error.TruncatedData;
        }
        /// Seek absolutely and disable prefix replay; a sequential source
        /// returns Unseekable.
        pub fn seek(self: *Input, offset: u64) Error!void {
            try self.source.seekTo(offset);
            self.prefix_pos = 4;
            self.position = offset;
        }
    };
};
