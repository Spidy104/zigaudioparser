//! Borrowed input with optional seeking and known size.
const std = @import("std");
const types = @import("types.zig");
const SeekableReader = @import("SeekableReader.zig");
const Source = @This();

reader: *std.Io.Reader,
seek_to: ?*const fn (*std.Io.Reader, u64) types.SeekError!void = null,
get_size: ?*const fn (*std.Io.Reader) types.SizeError!u64 = null,

/// Borrow sequential input. Keep reader, buffer, and input alive until decoding ends.
pub fn fromReader(reader: *std.Io.Reader) Source {
    return .{ .reader = reader };
}

/// Borrow input with seeking and size callbacks.
pub fn fromSeekable(source: SeekableReader) Source {
    return .{ .reader = source.reader, .seek_to = source.vtable.seekTo, .get_size = source.vtable.getSize };
}

/// Borrow a file reader; streaming files use sequential decoding.
pub fn fromFile(reader: *std.Io.File.Reader) Source {
    return fromSeekable(SeekableReader.fromFile(reader));
}

/// Borrow a fixed reader and its unchanged bytes.
pub fn fromFixed(reader: *std.Io.Reader) Source {
    return fromSeekable(SeekableReader.fromFixed(reader));
}

/// Seek absolutely, or return Unseekable without consuming input.
pub fn seekTo(self: Source, offset: u64) types.SourceSeekError!void {
    const seek = self.seek_to orelse return error.Unseekable;
    try seek(self.reader, offset);
}

/// Return input size if available; unknown size is null.
pub fn getSize(self: Source) types.SizeError!?u64 {
    const size = self.get_size orelse return null;
    return size(self.reader) catch |err| switch (err) {
        error.Unseekable => null,
        else => return err,
    };
}
