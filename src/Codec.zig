//! Audio decoder interface: encoded packets become PCM sample blocks.
//! Includes codec selection, the synchronous decoder adapter, and byte-stream
//! framing.
const std = @import("std");
const types = @import("types.zig");
const pcm = @import("codecs/pcm.zig");
const opus_enabled = @import("codec_options").opus;
const Codec = @This();

backend: Backend,
scheme: types.InputScheme,
/// Frames of decoding history required before an accurate seek target.
preroll_frames: u64 = 0,

// Exclude the C backend entirely in dependency-free builds.
const Backend = if (opus_enabled)
    union(enum) {
        pcm: *UnitAdapter(pcm),
        opus: *UnitAdapter(@import("codecs/opus.zig")),
    }
else
    union(enum) { pcm: *UnitAdapter(pcm) };

/// Open a built-in codec. The instance owns its state and output storage.
/// Allocates adapter state and the complete PCM output buffer here. Opus also
/// allocates aligned decoder state.
pub fn init(
    allocator: std.mem.Allocator,
    scheme: types.DecodingScheme,
    format: types.AudioFormat,
    options: types.Options,
) types.Error!Codec {
    if (format.channels == 0 or format.sample_rate == 0) {
        return error.InvalidData;
    }
    switch (scheme) {
        .pcm => |config| {
            const input_scheme = try pcm.scheme(config, format.channels);
            return .{
                .backend = .{
                    .pcm = try UnitAdapter(pcm)
                        .init(
                            allocator,
                            .{ .format = config, .channels = format.channels },
                            input_scheme,
                            1,
                            format,
                            options,
                        ),
                },
                .scheme = input_scheme,
            };
        },
        .opus => |config| {
            if (!opus_enabled) return error.UnsupportedEncoding;
            const opus = @import("codecs/opus.zig");
            return .{
                .backend = .{
                    .opus = try opus.init(allocator, config, format, options),
                },
                .scheme = .packets,
                .preroll_frames = opus.preroll_frames,
            };
        },
        else => return error.UnsupportedEncoding,
    }
}

/// Consume or copy the packet before returning accepted.
pub fn submit(self: *Codec, packet: types.Packet) types.Error!types.Submit {
    // Each inline branch retains its concrete adapter type.
    return switch (self.backend) {
        inline else => |backend| backend.submit(packet),
    };
}

/// Borrow output until the next codec operation.
pub fn receive(self: *Codec) types.Error!types.Receive {
    return switch (self.backend) {
        inline else => |backend| backend.receive(),
    };
}

/// End input and permit delayed output to drain.
pub fn finish(self: *Codec) types.Error!void {
    switch (self.backend) {
        inline else => |backend| try backend.finish(),
    }
}

/// Discard output and decoding history while retaining configuration.
pub fn reset(self: *Codec) void {
    switch (self.backend) {
        inline else => |backend| backend.reset(),
    }
}

/// Release codec state and output storage.
pub fn deinit(self: *Codec) void {
    switch (self.backend) {
        inline else => |backend| backend.deinit(),
    }
    self.* = undefined;
}

/// Adapt a codec supplying decodeUnit and reset to the packet lifecycle.
pub fn UnitAdapter(comptime Unit: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        unit: Unit,
        scheme: types.InputScheme,
        format: types.AudioFormat,
        max_frames_per_unit: u32,
        options: types.Options,
        output: []f32 = &.{},
        pending: ?types.AudioBlock = null,
        draining: bool = false,

        /// Allocate adapter state and PCM output before returning. Packet
        /// codecs
        /// reserve max_frames_per_unit * channels f32 samples; fixed-unit
        /// codecs
        /// reserve that many samples per unit fitting in
        /// options.bufferCapacity().
        /// Oversized submissions return LimitExceeded
        /// Ownership of unit transfers only on success.
        pub fn init(
            allocator: std.mem.Allocator,
            unit: Unit,
            scheme: types.InputScheme,
            max_frames_per_unit: u32,
            format: types.AudioFormat,
            options: types.Options,
        ) types.Error!*Self {
            if (
                max_frames_per_unit == 0
                    or format.channels == 0
                    or format.sample_rate == 0
            ) {
                return error.InvalidData;
            }
            var units: usize = 1;
            if (scheme.unitBytes()) |size| {
                if (size == 0) return error.InvalidData;
                if (size > options.bufferCapacity()) return error.LimitExceeded;
                units = options.bufferCapacity() / size;
            }
            const frames = std.math.mul(usize, units, max_frames_per_unit)
                catch return error.LimitExceeded;
            const capacity = std.math.mul(usize, frames, format.channels)
                catch return error.LimitExceeded;
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const output = try allocator.alloc(f32, capacity);
            self.* = .{
                .allocator = allocator,
                .unit = unit,
                .scheme = scheme,
                .format = format,
                .max_frames_per_unit = max_frames_per_unit,
                .options = options,
                .output = output,
            };
            return self;
        }

        fn submit(self: *Self, packet: types.Packet) types.Error!types.Submit {
            if (self.draining) return error.InvalidState;
            if (self.pending != null) return .receive_output_first;
            if (packet.bytes.len > self.options.max_payload_bytes) {
                return error.LimitExceeded;
            }
            if (packet.bytes.len == 0) return error.InvalidData;
            var units: usize = 1;
            if (self.scheme.unitBytes()) |size| {
                if (packet.bytes.len % size != 0) return error.InvalidData;
                units = packet.bytes.len / size;
            }
            const max_frames = std.math.mul(
                usize,
                units,
                self.max_frames_per_unit,
            )
                catch return error.LimitExceeded;
            const capacity = std.math.mul(
                usize,
                max_frames,
                self.format.channels,
            )
                catch return error.LimitExceeded;
            if (capacity > self.output.len) return error.LimitExceeded;
            const frames = try self.unit.decodeUnit(
                packet.bytes,
                self.output[0..capacity],
            );
            if (frames > capacity / self.format.channels) {
                return error.InvalidState;
            }
            self.pending = .{
                .samples = self.output[0..frames * self.format.channels],
                .format = self.format,
                .timestamp = packet.timestamp,
            };
            return .accepted;
        }

        fn receive(self: *Self) types.Error!types.Receive {
            if (self.pending) |block| {
                self.pending = null;
                return .{ .audio = block };
            }
            return if (self.draining) .finished else .need_input;
        }

        fn finish(self: *Self) types.Error!void {
            self.draining = true;
        }

        fn reset(self: *Self) void {
            self.pending = null;
            self.draining = false;
            self.unit.reset();
        }

        fn deinit(self: *Self) void {
            const allocator = self.allocator;
            if (@hasDecl(Unit, "deinit")) self.unit.deinit();
            allocator.free(self.output);
            allocator.destroy(self);
        }
    };
}

/// Gather complete fixed-size units from a byte stream for a codec.
/// Container readers that already supply packet boundaries bypass this helper.
pub const Framer = struct {
    allocator: std.mem.Allocator,
    scheme: types.InputScheme,
    buffer: []u8 = &.{},
    length: usize = 0,
    consumed: usize = 0,
    eof: bool = false,
    finished: bool = false,

    /// Container-delimited packets bypass this byte-stream gatherer.
    /// Allocates options.bufferCapacity() bytes here.
    pub fn init(
        allocator: std.mem.Allocator,
        scheme: types.InputScheme,
        options: types.Options,
    ) types.Error!Framer {
        if (scheme == .packets) return error.InvalidData;
        if (scheme.unitBytes()) |unit| {
            if (unit == 0) return error.InvalidData;
            if (unit > options.bufferCapacity()) return error.LimitExceeded;
        }
        if (options.bufferCapacity() == 0) return error.LimitExceeded;
        const buffer = try allocator.alloc(u8, options.bufferCapacity());
        return .{ .allocator = allocator, .scheme = scheme, .buffer = buffer };
    }

    /// Borrow the next encoded unit until the next call; null means fully
    /// drained EOF.
    /// reader must end at the encoded stream boundary, excluding container
    /// metadata.
    pub fn next(self: *Framer, reader: *std.Io.Reader) types.Error!?[]const u8 {
        if (self.finished) return null;
        self.compact();
        while (true) {
            const unit = self.scheme.unitBytes().?;
            const complete_bytes = self.length - self.length % unit;
            if (complete_bytes != 0) {
                self.consumed = complete_bytes;
                return self.buffer[0..complete_bytes];
            }
            if (self.eof) {
                if (self.length != 0) return error.TruncatedData;
                self.finished = true;
                return null;
            }
            if (self.length == self.buffer.len) return error.LimitExceeded;
            const count = try reader.readSliceShort(self.buffer[self.length..]);
            if (count == 0) self.eof = true;
            self.length += count;
        }
    }

    fn compact(self: *Framer) void {
        if (self.consumed != 0) {
            std.mem.copyForwards(
                u8,
                self.buffer[0..self.length - self.consumed],
                self.buffer[self.consumed..self.length],
            );
            self.length -= self.consumed;
            self.consumed = 0;
        }
    }

    /// Discard gathered bytes after seeking.
    pub fn reset(self: *Framer) void {
        self.length = 0;
        self.consumed = 0;
        self.eof = false;
        self.finished = false;
    }

    /// Release the gathering buffer.
    pub fn deinit(self: *Framer) void {
        self.allocator.free(self.buffer);
        self.* = undefined;
    }
};
