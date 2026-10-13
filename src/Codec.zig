//! Codec registry and shared adapter for synchronous unit decoding.
const std = @import("std");
const types = @import("types.zig");
const decoding = @import("decoding.zig");
const pcm = @import("decoders/pcm.zig");
const Codec = @This();

context: *anyopaque,
vtable: *const VTable,
scheme: decoding.InputScheme,
/// Frames of decoding history required before an accurate seek target.
preroll_frames: u64 = 0,

pub const VTable = struct {
    submit: *const fn (*anyopaque, decoding.Packet) decoding.Error!decoding.Submit,
    receive: *const fn (*anyopaque) decoding.Error!decoding.Receive,
    finish: *const fn (*anyopaque) decoding.Error!void,
    reset: *const fn (*anyopaque) void,
    deinit: *const fn (*anyopaque) void,
};

/// Open a registered codec. The instance owns its state and output storage.
pub fn init(allocator: std.mem.Allocator, scheme: types.DecodingScheme, format: decoding.AudioFormat, options: decoding.Options) decoding.Error!Codec {
    if (format.channels == 0 or format.sample_rate == 0) return error.InvalidData;
    return switch (scheme) {
        .pcm => |config| UnitAdapter(pcm).init(allocator, .{ .format = config, .channels = format.channels }, try pcm.scheme(config, format.channels), 1, format, options),
        else => error.UnsupportedEncoding,
    };
}

/// Consume or copy the packet before returning accepted.
pub fn submit(self: *Codec, packet: decoding.Packet) decoding.Error!decoding.Submit {
    return self.vtable.submit(self.context, packet);
}

/// Borrow output until the next codec operation.
pub fn receive(self: *Codec) decoding.Error!decoding.Receive {
    return self.vtable.receive(self.context);
}

/// End input and permit delayed output to drain.
pub fn finish(self: *Codec) decoding.Error!void {
    try self.vtable.finish(self.context);
}

/// Discard output and decoding history while retaining configuration.
pub fn reset(self: *Codec) void {
    self.vtable.reset(self.context);
}

/// Release codec state and output storage.
pub fn deinit(self: *Codec) void {
    self.vtable.deinit(self.context);
    self.* = undefined;
}

/// Adapt a codec supplying decodeUnit and reset to the packet lifecycle.
pub fn UnitAdapter(comptime Unit: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        unit: Unit,
        scheme: decoding.InputScheme,
        format: decoding.AudioFormat,
        max_frames_per_unit: u32,
        options: decoding.Options,
        output: []f32 = &.{},
        pending: ?decoding.AudioBlock = null,
        draining: bool = false,

        /// Allocate output for at most max_frames_per_unit frames per encoded unit.
        pub fn init(allocator: std.mem.Allocator, unit: Unit, scheme: decoding.InputScheme, max_frames_per_unit: u32, format: decoding.AudioFormat, options: decoding.Options) decoding.Error!Codec {
            if (max_frames_per_unit == 0 or format.channels == 0 or format.sample_rate == 0) return error.InvalidData;
            if (scheme.unitBytes()) |size| {
                if (size == 0) return error.InvalidData;
            }
            const self = try allocator.create(Self);
            self.* = .{ .allocator = allocator, .unit = unit, .scheme = scheme, .format = format, .max_frames_per_unit = max_frames_per_unit, .options = options };
            return .{ .context = self, .vtable = &.{ .submit = submitPacket, .receive = receiveBlock, .finish = finishInput, .reset = resetState, .deinit = destroy }, .scheme = scheme };
        }

        fn submitPacket(context: *anyopaque, packet: decoding.Packet) decoding.Error!decoding.Submit {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.draining) return error.InvalidState;
            if (self.pending != null) return .receive_output_first;
            if (packet.bytes.len > self.options.max_payload_bytes) return error.LimitExceeded;
            if (packet.bytes.len == 0) return error.InvalidData;
            const units = if (self.scheme.unitBytes()) |size| blk: {
                if (packet.bytes.len % size != 0) return error.InvalidData;
                break :blk packet.bytes.len / size;
            } else 1;
            const max_frames = std.math.mul(usize, units, self.max_frames_per_unit) catch return error.LimitExceeded;
            const capacity = std.math.mul(usize, max_frames, self.format.channels) catch return error.LimitExceeded;
            if (capacity > self.output.len) self.output = try self.allocator.realloc(self.output, capacity);
            const frames = try self.unit.decodeUnit(packet.bytes, self.output[0..capacity]);
            if (frames > capacity / self.format.channels) return error.InvalidState;
            self.pending = .{ .samples = self.output[0 .. frames * self.format.channels], .format = self.format, .timestamp = packet.timestamp };
            return .accepted;
        }

        fn receiveBlock(context: *anyopaque) decoding.Error!decoding.Receive {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.pending) |block| {
                self.pending = null;
                return .{ .audio = block };
            }
            return if (self.draining) .finished else .need_input;
        }

        fn finishInput(context: *anyopaque) decoding.Error!void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.draining = true;
        }

        fn resetState(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.pending = null;
            self.draining = false;
            self.unit.reset();
        }

        fn destroy(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const allocator = self.allocator;
            if (@hasDecl(Unit, "deinit")) self.unit.deinit();
            allocator.free(self.output);
            allocator.destroy(self);
        }
    };
}
