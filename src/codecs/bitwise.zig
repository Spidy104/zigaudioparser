//! ogg bit packing; writers own storage and readers borrow input.
const std = @import("std");

const State = struct {
    endByte: usize = 0,
    endBit: u3 = 0,
    buffer: []const u8 = &.{},
    allocation: ?[]u8 = null,
    allocator: ?std.mem.Allocator = null,
    failed: bool = false,
};

pub const WriteError = std.mem.Allocator.Error
    || error{
        InvalidBitCount,
        InvalidTruncation,
        ShortSource,
        NotWriter,
        Overflow,
    };
const bufferIncrement = 256;

fn writeInit(
    state: *State,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    state.* = .{};
    const memory = try allocator.alloc(u8, bufferIncrement);
    memory[0] = 0;
    state.* = .{
        .buffer = memory,
        .allocation = memory,
        .allocator = allocator,
    };
}

fn grow(state: *State, size: usize) WriteError!void {
    const allocator = state.allocator orelse return error.NotWriter;
    const memory = try allocator.realloc(state.allocation.?, size);
    state.allocation = memory;
    state.buffer = memory;
}

fn writeValue(
    comptime most_significant_first: bool,
    state: *State,
    value: u32,
    width: u6,
) WriteError!void {
    if (!valid(state)) return error.NotWriter;
    errdefer clear(state);
    if (width > 32) return error.InvalidBitCount;
    if (state.endByte >= state.buffer.len - 4) {
        try grow(
            state,
            std.math.add(usize, state.buffer.len, bufferIncrement)
                catch return error.Overflow,
        );
    }
    const masked = value & lowMask(width);
    const total: u6 = width + @as(u6, state.endBit);
    const memory = state.allocation.?;
    // 64 bits hold the value plus its partial-byte offset.
    const word = if (most_significant_first)
        @as(u64, masked) << @as(u6, @intCast(40 - total))
    else
        @as(u64, masked) << state.endBit;
    const first: u8 = @truncate(
        if (most_significant_first) word >> 32 else word,
    );
    memory[state.endByte] |= first;
    var byte_index: u6 = 1;
    while (byte_index <= total / 8) : (byte_index += 1) {
        const shift: u6 = if (most_significant_first)
            (4 - byte_index) * 8
        else
            byte_index * 8;
        memory[state.endByte + byte_index] = @truncate(word >> shift);
    }
    state.endByte += total / 8;
    state.endBit = @truncate(total);
}

fn lowMask(width: u6) u32 {
    if (width == 0) return 0;
    const shift: u5 = @intCast(32 - width);
    const mask: u32 = std.math.maxInt(u32);
    return mask >> shift;
}

fn trunc(
    comptime most_significant_first: bool,
    state: *State,
    bits: usize,
) WriteError!void {
    if (!valid(state)) return error.NotWriter;
    if (bits > countBits(state)) return error.InvalidTruncation;
    state.endByte = bits / 8;
    state.endBit = @truncate(bits);
    const keep: u8 = if (most_significant_first)
        @truncate(@as(u16, 0xff00) >> state.endBit)
    else
        @truncate(lowMask(state.endBit));
    state.allocation.?[state.endByte] &= keep;
}

fn writeAlign(
    comptime most_significant_first: bool,
    state: *State,
) WriteError!void {
    if (state.endBit != 0)
        try writeValue(
            most_significant_first,
            state,
            0,
            8 - @as(u6, state.endBit),
        );
}

fn writeCopy(
    comptime most_significant_first: bool,
    state: *State,
    source: []const u8,
    bits: usize,
) WriteError!void {
    if (!valid(state)) return error.NotWriter;
    errdefer clear(state);
    const bytes = bits / 8;
    const trailing: u3 = @truncate(bits);
    if (bytes > source.len or (bytes == source.len and trailing != 0))
        return error.ShortSource;
    const total = std.math.add(usize, bits, state.endBit)
        catch return error.Overflow;
    const end = std.math.add(usize, state.endByte, total / 8)
        catch return error.Overflow;

    // preserve an aliased source across reallocations.
    var input = source;
    const source_address = @intFromPtr(source.ptr);
    const buffer_address = @intFromPtr(state.buffer.ptr);
    var offset: ?usize = null;
    if (source.len != 0 and source_address >= buffer_address) {
        const distance = source_address - buffer_address;
        if (distance < state.buffer.len) offset = distance;
    }
    if (offset) |start| {
        if (source.len > state.buffer.len - start) return error.ShortSource;
    }
    if (end >= state.buffer.len) {
        try grow(
            state,
            std.math.add(usize, end, bufferIncrement)
                catch return error.Overflow,
        );
        if (offset) |start| input = state.buffer[start..][0..source.len];
    }
    if (state.endBit != 0) {
        // reserve headroom and rebase aliased input after reallocations.
        for (0..bytes) |byte_index| {
            const byte = input[byte_index];
            try writeValue(most_significant_first, state, byte, 8);
            if (offset) |start| input = state.buffer[start..][0..source.len];
        }
    } else {
        const destination = state.allocation.?[state.endByte..][0..bytes];
        if (@intFromPtr(destination.ptr) <= @intFromPtr(input.ptr)) {
            std.mem.copyForwards(u8, destination, input[0..bytes]);
        } else {
            std.mem.copyBackwards(u8, destination, input[0..bytes]);
        }
        state.endByte += bytes;
        state.allocation.?[state.endByte] = 0;
    }
    if (trailing != 0) {
        const value = if (most_significant_first)
            input[bytes] >> @as(u3, @intCast(8 - @as(u4, trailing)))
        else
            input[bytes];
        try writeValue(most_significant_first, state, value, trailing);
    }
}

fn overflow(state: *State) void {
    state.endByte = state.buffer.len;
    state.endBit = 1;
    state.failed = true;
}

fn look(
    comptime most_significant_first: bool,
    state: *const State,
    width: u6,
) ?u32 {
    if (width > 32 or state.failed or state.endByte > state.buffer.len)
        return null;
    const total: u6 = width + @as(u6, state.endBit);
    const bytes: usize = (@as(usize, total) + 7) / 8;
    if (bytes > state.buffer.len - state.endByte) return null;
    if (width == 0) return 0;
    var word: u64 = 0;
    for (state.buffer[state.endByte..][0..bytes], 0..) |byte, byte_index| {
        if (most_significant_first) {
            word = (word << 8) | byte;
        } else {
            word |= @as(u64, byte) << @as(u6, @intCast(byte_index * 8));
        }
    }
    const shift: u6 = if (most_significant_first)
        @intCast(bytes * 8 - total)
    else
        state.endBit;
    return @as(u32, @truncate(word >> shift)) & lowMask(width);
}

fn readValue(
    comptime most_significant_first: bool,
    state: *State,
    width: u6,
) ?u32 {
    const value = look(most_significant_first, state, width) orelse {
        overflow(state);
        return null;
    };
    advanceCursor(state, width);
    return value;
}

fn valid(state: *const State) bool {
    return state.allocation != null and !state.failed;
}

fn resetState(state: *State) void {
    if (!valid(state)) return;
    state.endByte = 0;
    state.endBit = 0;
    state.allocation.?[0] = 0;
}

fn clear(state: *State) void {
    if (state.allocation) |memory| state.allocator.?.free(memory);
    state.* = .{};
}

fn advanceCursor(state: *State, bits: usize) void {
    const total = std.math.add(usize, bits, state.endBit) catch {
        overflow(state);
        return;
    };
    const needed = total / 8 + @intFromBool(total % 8 != 0);
    if (
        state.failed
            or state.endByte > state.buffer.len
            or needed > state.buffer.len - state.endByte
    ) {
        overflow(state);
        return;
    }
    state.endByte += total / 8;
    state.endBit = @truncate(total);
}

fn countBytes(state: *const State) usize {
    return state.endByte + @intFromBool(state.endBit != 0);
}

fn countBits(state: *const State) usize {
    return state.endByte * 8 + state.endBit;
}

/// return written bytes for writers, or the full input for readers.
fn getBytes(state: *const State) []const u8 {
    return if (state.allocation != null)
        state.buffer[0..countBytes(state)]
    else
        state.buffer;
}

/// select bit order at compile time: little is lsb first, big is msb first.
/// keep borrowed input unchanged while reading.
pub fn BitReader(comptime order: std.builtin.Endian) type {
    return struct {
        const Self = @This();
        state: State,

        pub fn init(input: []const u8) Self {
            return .{ .state = .{ .buffer = input } };
        }

        /// failed peeks leave the cursor unchanged.
        pub fn peek(self: *const Self, width: u6) ?u32 {
            return look(order == .big, &self.state, width);
        }

        pub fn peekBit(self: *const Self) ?u1 {
            const value = self.peek(1) orelse return null;
            return @intCast(value);
        }

        /// failed reads exhaust the reader, matching libogg.
        pub fn read(self: *Self, width: u6) ?u32 {
            return readValue(order == .big, &self.state, width);
        }

        pub fn readBit(self: *Self) ?u1 {
            const value = self.read(1) orelse return null;
            return @intCast(value);
        }

        pub fn advance(self: *Self, bits: usize) void {
            advanceCursor(&self.state, bits);
        }

        pub fn advanceBit(self: *Self) void {
            self.advance(1);
        }

        pub fn bitCount(self: *const Self) usize {
            return countBits(&self.state);
        }

        pub fn byteCount(self: *const Self) usize {
            return countBytes(&self.state);
        }

        pub fn isExhausted(self: *const Self) bool {
            return self.state.failed;
        }

        pub fn bytes(self: *const Self) []const u8 {
            return self.state.buffer;
        }
    };
}

/// own output storage; write or copy failures free it and require
/// reinitialization.
pub fn BitWriter(comptime order: std.builtin.Endian) type {
    return struct {
        const Self = @This();
        state: State = .{},

        pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Self {
            var self: Self = .{};
            try writeInit(&self.state, allocator);
            return self;
        }

        pub fn deinit(self: *Self) void {
            clear(&self.state);
        }

        pub fn isValid(self: *const Self) bool {
            return valid(&self.state);
        }

        pub fn reset(self: *Self) void {
            resetState(&self.state);
        }

        pub fn write(self: *Self, value: u32, width: u6) WriteError!void {
            try writeValue(order == .big, &self.state, value, width);
        }

        pub fn copy(
            self: *Self,
            source: []const u8,
            bits: usize,
        ) WriteError!void {
            try writeCopy(order == .big, &self.state, source, bits);
        }

        pub fn truncate(self: *Self, bits: usize) WriteError!void {
            try trunc(order == .big, &self.state, bits);
        }

        pub fn alignToByte(self: *Self) WriteError!void {
            try writeAlign(order == .big, &self.state);
        }

        pub fn bitCount(self: *const Self) usize {
            return countBits(&self.state);
        }

        pub fn byteCount(self: *const Self) usize {
            return countBytes(&self.state);
        }

        /// borrow written bytes until mutation or cleanup.
        pub fn bytes(self: *const Self) []const u8 {
            return getBytes(&self.state);
        }
    };
}
