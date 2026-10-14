//! Borrowed vendor/comment fields shared by Vorbis, OpusTags, and FLAC.
//! Caller must handle codec signatures, framing bits, and trailing padding.
//! Keep the input bytes alive and unchanged while reading these fields.
const std = @import("std");
const Error = @import("../types.zig").ValidationError;
const Self = @This();

vendor: []const u8,
/// Unconsumed fields, followed by any codec-specific trailer. After next()
/// returns null, only the trailer remains for the caller to validate.
remaining: []const u8,
comments_left: u32,

/// Read the vendor and comment count after the codec-specific signature.
/// Iterate through all comments to validate their lengths as well.
pub fn init(bytes: []const u8) Error!Self {
    var remaining = bytes;
    const vendor = try readField(&remaining);
    // The count and each subsequent field length are little-endian u32 values.
    if (remaining.len < 4) return error.InvalidData;
    const count = std.mem.readInt(u32, remaining[0..4], .little);
    remaining = remaining[4..];
    if (count > remaining.len / 4) return error.InvalidData;
    return .{
        .vendor = vendor,
        .remaining = remaining,
        .comments_left = count,
    };
}

/// Borrow the next comment, or null once the declared count has been consumed.
/// This validates byte lengths; field names and text interpretation belong to
/// the caller. An empty comment is distinct from the end of the list.
pub fn next(self: *Self) Error!?[]const u8 {
    if (self.comments_left == 0) return null;
    const comment = try readField(&self.remaining);
    self.comments_left -= 1;
    return comment;
}

fn readField(remaining: *[]const u8) Error![]const u8 {
    if (remaining.len < 4) return error.InvalidData;
    const length = std.mem.readInt(u32, remaining.*[0..4], .little);
    if (length > remaining.len - 4) return error.InvalidData;
    const field = remaining.*[4..][0..length];
    remaining.* = remaining.*[4 + @as(usize, length)..];
    return field;
}
