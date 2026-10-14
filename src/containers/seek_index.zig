//! Bounded seek indexes; callers define locations and the frame timeline.
const std = @import("std");
const Error = @import("../types.zig").Error;

pub fn Index(comptime Location: type) type {
    return struct {
        const Self = @This();
        pub const Entry = struct { frame: u64, location: Location };

        entries: std.ArrayList(Entry) = .empty,

        /// Append in nondecreasing frame order during initialization only.
        /// Both entry storage and spare capacity stay within the byte limit.
        pub fn append(
            self: *Self,
            allocator: std.mem.Allocator,
            limit: usize,
            entry: Entry,
        ) Error!void {
            if (
                self.entries.items.len != 0
                    and entry.frame
                        < self.entries.items[self.entries.items.len - 1].frame
            ) {
                return error.InvalidData;
            }
            const max_entries = limit / @sizeOf(Entry);
            if (self.entries.items.len >= max_entries) {
                return error.LimitExceeded;
            }
            if (self.entries.items.len == self.entries.capacity) {
                // Start with up to 64 entries, then double within the budget.
                const capacity = @min(
                    max_entries,
                    @max(@as(usize, 64), self.entries.capacity *| 2),
                );
                try self.entries.ensureTotalCapacityPrecise(
                    allocator,
                    capacity,
                );
            }
            self.entries.appendAssumeCapacity(entry);
        }

        /// Find the last entry at/before target, or the first for earlier
        /// targets.
        /// An empty index returns null.
        pub fn atOrBefore(self: *const Self, target: u64) ?Entry {
            if (self.entries.items.len == 0) return null;
            var low: usize = 0;
            var high = self.entries.items.len;
            while (low < high) {
                const midpoint = low + (high - low) / 2;
                if (self.entries.items[midpoint].frame <= target) {
                    low = midpoint + 1;
                } else {
                    high = midpoint;
                }
            }
            return self.entries.items[low -| 1];
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.entries.deinit(allocator);
            self.* = .{};
        }
    };
}
