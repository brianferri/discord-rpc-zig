//! An `Io.Reader` over a run of `length` bytes, carrying a deadline.
//!
//! Take the interface with `&reader.interface`; the object must outlive it and stay put.
//! A read that fails reports `error.ReadFailed` and leaves the cause in `err`.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const transport = @import("root.zig");
const Transport = transport.Transport;

const Reader = @This();

io: Io,
endpoint: *Transport,

timeout: Io.Timeout,

/// What the peer still owes; the stream ends here.
remaining: u32,

interface: Io.Reader,

/// What the last `error.ReadFailed` stood for.
err: ?transport.OperationError,

pub fn init(
    endpoint: *Transport,
    io: Io,
    timeout: Io.Timeout,
    length: u32,
    buffer: []u8,
) Reader {
    assert(buffer.len > 0);

    return .{
        .io = io,
        .endpoint = endpoint,
        .timeout = timeout.toDeadline(io),
        .remaining = length,
        .interface = .{
            .vtable = &.{ .stream = stream },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        },
        .err = null,
    };
}

fn stream(io_reader: *Io.Reader, writer: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const reader: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));
    if (reader.remaining == 0) return error.EndOfStream;

    const room = limit.min(.limited(reader.remaining));
    const destination = room.slice(try writer.writableSliceGreedy(1));
    if (destination.len == 0) return 0;
    assert(destination.len <= reader.remaining);

    const count = reader.endpoint.read(reader.io, destination, reader.timeout) catch |failure| {
        reader.err = failure;
        return error.ReadFailed;
    };

    assert(count <= destination.len);
    reader.remaining -= @intCast(count);
    writer.advance(count);
    return count;
}
