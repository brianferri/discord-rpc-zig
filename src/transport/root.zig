//! Platform transport for Discord's local IPC endpoint, selected at compile time.

const std = @import("std");

pub const endpoint = @import("endpoint.zig");
pub const Reader = @import("Reader.zig");

pub const Transport = switch (endpoint.family) {
    .socket => @import("Socket.zig"),
    .pipe => @import("Pipe.zig"),
};

/// What any endpoint operation carrying a deadline can fail with, in either direction.
pub const OperationError = endpoint.Error || std.Io.Timeout.Error || std.Io.ConcurrentError;

/// Fills `buffer` completely. The deadline covers the whole fill.
pub fn readAll(
    transport: *Transport,
    io: std.Io,
    buffer: []u8,
    timeout: std.Io.Timeout,
) OperationError!void {
    std.debug.assert(buffer.len > 0);

    const deadline = timeout.toDeadline(io);

    var filled: usize = 0;
    while (filled < buffer.len) {
        const count = try transport.read(io, buffer[filled..], deadline);
        std.debug.assert(count > 0);
        filled += count;
    }

    std.debug.assert(filled == buffer.len);
}

/// Hands over all of `bytes`. The deadline covers the whole write; reaching it leaves a
/// partial frame in the peer's stream, so the caller must drop the connection.
pub fn writeAll(
    transport: *Transport,
    io: std.Io,
    bytes: []const u8,
    timeout: std.Io.Timeout,
) OperationError!void {
    std.debug.assert(bytes.len > 0);

    const deadline = timeout.toDeadline(io);

    var written: usize = 0;
    while (written < bytes.len) {
        const count = try transport.write(io, bytes[written..], deadline);
        std.debug.assert(count > 0);
        written += count;
    }

    std.debug.assert(written == bytes.len);
}

test {
    _ = endpoint;
    _ = Reader;
    _ = Transport;
    _ = &readAll;
    _ = &writeAll;
}
