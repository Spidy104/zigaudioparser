//! Borrowed input with optional seeking and known size.
const std = @import("std");
const types = @import("types.zig");
const Source = @This();

reader: *std.Io.Reader,
seek_to: ?*const fn (*std.Io.Reader, u64) types.SeekError!void = null,
get_size: ?*const fn (*std.Io.Reader) types.SizeError!u64 = null,

/// Borrow sequential input. Keep reader, buffer, and input alive until decoding
/// ends.
pub fn fromReader(reader: *std.Io.Reader) Source {
    return .{ .reader = reader };
}

/// Borrow a file reader; streaming files use sequential decoding.
pub fn fromFile(reader: *std.Io.File.Reader) Source {
    return .{
        .reader = &reader.interface,
        .seek_to = fileSeek,
        .get_size = fileSize,
    };
}

/// Borrow a fixed reader and its unchanged bytes.
pub fn fromFixed(reader: *std.Io.Reader) Source {
    return .{ .reader = reader, .seek_to = fixedSeek, .get_size = fixedSize };
}

/// Seek absolutely, or return Unseekable without consuming input.
pub fn seekTo(self: Source, offset: u64) types.SourceSeekError!void {
    const seek = self.seek_to orelse return error.Unseekable;
    try seek(self.reader, offset);
}

/// Return input size if available; unknown size is null.
pub fn getSize(self: Source) types.SizeError!?u64 {
    const size = self.get_size orelse return null;
    return size(self.reader)
        catch |err| switch (err) {
            error.Unseekable => null,
            else => return err,
        };
}

/// Seek a file reader and update its buffered position.
fn fileSeek(reader: *std.Io.Reader, offset: u64) types.SeekError!void {
    const file: *std.Io.File.Reader = @fieldParentPtr("interface", reader);
    try file.seekTo(offset);
}

/// Return file size, reporting Unseekable for streaming input.
fn fileSize(reader: *std.Io.Reader) types.SizeError!u64 {
    const file: *std.Io.File.Reader = @fieldParentPtr("interface", reader);
    return file.getSize()
        catch |err| switch (err) {
            error.Streaming => error.Unseekable,
            else => |size_error| size_error,
        };
}

/// Set a fixed reader's position; offsets beyond its buffer return EndOfStream.
fn fixedSeek(reader: *std.Io.Reader, offset: u64) types.SeekError!void {
    if (offset > reader.end) return error.EndOfStream;
    reader.seek = @intCast(offset);
}

/// Return the full input length of a fixed reader.
fn fixedSize(reader: *std.Io.Reader) types.SizeError!u64 {
    return reader.end;
}
