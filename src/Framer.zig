//! Bounded gathering of fixed units or parsed byte streams.
const std = @import("std");
const decoding = @import("decoding.zig");
const Framer = @This();

allocator: std.mem.Allocator,
scheme: decoding.InputScheme,
parser: ?decoding.BitstreamParser,
limit: usize,
buffer: []u8 = &.{},
length: usize = 0,
consumed: usize = 0,
eof: bool = false,
finished: bool = false,
empty_steps: usize = 0,

/// Own parser state when supplied; parsed framing requires a parser.
/// Container-delimited packets bypass this byte-stream gatherer.
pub fn init(allocator: std.mem.Allocator, scheme: decoding.InputScheme, parser: ?decoding.BitstreamParser, options: decoding.Options) decoding.Error!Framer {
    if (scheme == .packets or (scheme == .parsed) != (parser != null)) return error.InvalidData;
    if (scheme.unitBytes()) |unit| {
        if (unit == 0) return error.InvalidData;
        if (unit > options.max_payload_bytes) return error.LimitExceeded;
    }
    if (options.max_payload_bytes == 0) return error.LimitExceeded;
    return .{ .allocator = allocator, .scheme = scheme, .parser = parser, .limit = options.max_payload_bytes };
}

/// Borrow the next encoded unit until the next call; null means fully drained EOF.
/// reader must end at the encoded stream boundary, excluding container metadata.
pub fn next(self: *Framer, reader: *std.Io.Reader) decoding.Error!?[]const u8 {
    if (self.finished) return null;
    self.compact();
    while (true) {
        if (self.parser) |parser| {
            const result = try parser.vtable.parse(parser.context, self.buffer[0..self.length], self.eof);
            if (result.consumed > self.length) return error.InvalidState;
            self.consumed = result.consumed;
            if (result.packet) |packet| {
                if (packet.len == 0) return error.InvalidState;
                if (packet.len > self.limit) return error.LimitExceeded;
                if (result.consumed == 0) {
                    self.empty_steps += 1;
                    if (self.empty_steps > 1024) return error.InvalidState;
                } else self.empty_steps = 0;
                return packet;
            }
            if (self.eof and result.consumed == 0) {
                if (self.length != 0) return error.TruncatedData;
                self.finished = true;
                return null;
            }
            if (result.consumed != 0) {
                self.compact();
                continue;
            }
        } else {
            const unit = self.scheme.unitBytes().?;
            const count = self.length - self.length % unit;
            if (count != 0) {
                self.consumed = count;
                return self.buffer[0..count];
            }
            if (self.eof) {
                if (self.length != 0) return error.TruncatedData;
                self.finished = true;
                return null;
            }
        }
        if (self.eof) return error.InvalidState;
        if (self.length == self.buffer.len) {
            if (self.length == self.limit) return error.LimitExceeded;
            const capacity = @min(self.limit, @max(@as(usize, 8192), self.buffer.len +| self.buffer.len));
            self.buffer = try self.allocator.realloc(self.buffer, capacity);
        }
        const count = try reader.readSliceShort(self.buffer[self.length..]);
        if (count == 0) self.eof = true;
        self.length += count;
        if (count != 0) self.empty_steps = 0;
    }
}

fn compact(self: *Framer) void {
    if (self.consumed != 0) {
        std.mem.copyForwards(u8, self.buffer[0 .. self.length - self.consumed], self.buffer[self.consumed..self.length]);
        self.length -= self.consumed;
        self.consumed = 0;
    }
}

/// Discard gathered bytes and parser history after seeking.
pub fn reset(self: *Framer) void {
    self.length = 0;
    self.consumed = 0;
    self.eof = false;
    self.finished = false;
    self.empty_steps = 0;
    if (self.parser) |parser| parser.vtable.reset(parser.context);
}

/// Release the parser and gathering buffer.
pub fn deinit(self: *Framer) void {
    if (self.parser) |parser| parser.vtable.deinit(parser.context);
    self.allocator.free(self.buffer);
    self.* = undefined;
}
