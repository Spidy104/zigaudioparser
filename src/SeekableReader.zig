//! Borrowed reader with seeking and known size.
//! Caller owns input. Do not read or seek independently while decoding.
const std = @import("std");
const types = @import("types.zig");
const SeekableReader = @This();

reader: *std.Io.Reader,
vtable: *const VTable,

/// Callbacks for seeking and input size.
pub const VTable = struct {
    /// Set absolute byte position, update source and reader buffer together.
    seekTo: *const fn (*std.Io.Reader, u64) types.SeekError!void,
    /// Return full input size in bytes.
    getSize: *const fn (*std.Io.Reader) types.SizeError!u64,
};

/// Seek to an absolute byte offset.
pub fn seekTo(self: SeekableReader, offset: u64) types.SeekError!void {
    return self.vtable.seekTo(self.reader, offset);
}

/// Return input size in bytes.
pub fn getSize(self: SeekableReader) types.SizeError!u64 {
    return self.vtable.getSize(self.reader);
}

/// Wrap a seekable file reader, caller keeps ownership.
/// Keep reader and buffer in place, keep file open while in use.
pub fn fromFile(reader: *std.Io.File.Reader) SeekableReader {
    return .{ .reader = &reader.interface, .vtable = &.{ .seekTo = fileSeek, .getSize = fileSize } };
}

/// Wrap a reader initialized with std.Io.Reader.fixed.
/// Keep reader in place and bytes alive and unchanged while in use.
pub fn fromFixed(reader: *std.Io.Reader) SeekableReader {
    return .{ .reader = reader, .vtable = &.{ .seekTo = fixedSeek, .getSize = fixedSize } };
}

fn fileSeek(reader: *std.Io.Reader, offset: u64) types.SeekError!void {
    const file: *std.Io.File.Reader = @fieldParentPtr("interface", reader);
    try file.seekTo(offset);
}

fn fileSize(reader: *std.Io.Reader) types.SizeError!u64 {
    const file: *std.Io.File.Reader = @fieldParentPtr("interface", reader);
    return file.getSize() catch |err| switch (err) {
        error.Streaming => error.Unseekable,
        else => |e| e,
    };
}

fn fixedSeek(reader: *std.Io.Reader, offset: u64) types.SeekError!void {
    if (offset > reader.end) return error.EndOfStream;
    reader.seek = @intCast(offset);
}

fn fixedSize(reader: *std.Io.Reader) types.SizeError!u64 {
    return reader.end;
}
