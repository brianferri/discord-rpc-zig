//! Frames and handshakes over a platform transport.
//!
//! A frame is a little-endian opcode and payload length, then that many bytes.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const text = @import("../text.zig");
const serialize = @import("serialize.zig");
const parse = @import("parse.zig");
const transport = @import("../transport/root.zig");
const milliseconds = @import("../timeout.zig").milliseconds;
const Transport = transport.Transport;

const Connection = @This();

pub const max_frame_size: u32 = 64 * 1024;
pub const header_size: u32 = 8;
pub const max_payload_size: u32 = max_frame_size - header_size;

comptime {
    assert(max_payload_size <= parse.max_value_bytes);
}

pub const version: u32 = 1;

/// How long a payload the peer has already announced may take to arrive.
pub const payload_timeout_ms: u64 = 30 * 1000;

const payload_timeout: Io.Timeout = milliseconds(payload_timeout_ms);

pub const max_handshake_size: u32 = 512;

pub const Opcode = enum(u32) {
    handshake = 0,
    frame = 1,
    close = 2,
    ping = 3,
    pong = 4,
    _,
};

pub const State = enum {
    disconnected,
    sent_handshake,
    connected,
};

/// Failures detected here. They share `Client.Status.code` with the codes Discord
/// sends in an ERROR payload.
pub const ErrorCode = enum(i32) {
    success = 0,
    pipe_closed = 1,
    read_corrupt = 2,
    timed_out = 3,
    unavailable = 4,
    _,

    pub fn message(code: ErrorCode) []const u8 {
        return switch (code) {
            .success => "",
            .pipe_closed => "Pipe closed",
            .read_corrupt => "Bad ipc frame",
            .timed_out => "Timed out",
            .unavailable => "System resources unavailable",
            _ => "Unknown error",
        };
    }
};

pub const Message = union(enum) {
    frame: Payload,
    closed: parse.Frame,
    /// How much of the ping `read` staged in the caller's chunk; `echoPong` sends it.
    ping: u32,
    pong,
};

/// A walked frame, beside how much of the payload it came from is still in the caller's
/// chunk: a reply carrying more than `Frame` holds is walked again from there.
pub const Payload = struct {
    frame: parse.Frame,
    length: u32,
};

pub const OpenError = Transport.OpenError || transport.OperationError || serialize.Error;
pub const ReadError = transport.OperationError || parse.Error || error{ FrameTooLarge, BadFrame };
pub const WriteError = transport.OperationError || error{PayloadTooLarge};
pub const EchoError = transport.OperationError;

endpoint: ?Transport,
state: State,
application_id: text.Buffer(64),

/// What a read drew off the endpoint past the frame it answered with, waiting at `pending_at`
/// in the chunk that read was given.
pending: u32,
pending_at: u32,

pub fn init(application_id: []const u8) Connection {
    var connection: Connection = .{
        .endpoint = null,
        .state = .disconnected,
        .application_id = .empty,
        .pending = 0,
        .pending_at = 0,
    };
    connection.application_id.set(application_id);
    return connection;
}

pub fn deinit(connection: *Connection, io: Io) void {
    connection.close(io);
    connection.* = undefined;
}

pub fn isOpen(connection: *const Connection) bool {
    return connection.state == .connected;
}

/// The peer answers with a `READY` dispatch, which the caller confirms with `markConnected`.
pub fn open(connection: *Connection, io: Io, environ: *std.process.Environ.Map) OpenError!void {
    assert(connection.state == .disconnected);
    assert(connection.endpoint == null);

    var endpoint = try Transport.open(io, environ);
    errdefer endpoint.close(io);

    var frame: [header_size + max_handshake_size]u8 = undefined;
    const length = try serialize.handshake(
        frame[header_size..],
        version,
        connection.application_id.slice(),
    );
    try writeFrame(&endpoint, io, &frame, .handshake, length);

    connection.endpoint = endpoint;
    connection.state = .sent_handshake;
    assert(connection.endpoint != null);
}

pub fn markConnected(connection: *Connection) void {
    assert(connection.state == .sent_handshake);
    assert(connection.endpoint != null);
    connection.state = .connected;
    assert(connection.isOpen());
}

pub fn close(connection: *Connection, io: Io) void {
    if (connection.endpoint) |*endpoint| endpoint.close(io);
    connection.endpoint = null;
    connection.state = .disconnected;
    connection.pending = 0;
    connection.pending_at = 0;

    assert(!connection.isOpen());
    assert(connection.pending == 0);
}

/// `frame` carries its payload at `header_size`, leaving room for the header written here.
pub fn write(
    connection: *Connection,
    io: Io,
    opcode: Opcode,
    frame: []u8,
    length: u32,
) WriteError!void {
    assert(connection.state != .disconnected);
    assert(opcode != .handshake);

    // Refused before the assertion below sums it, which would overflow near the top of u32.
    if (length > max_payload_size) return error.PayloadTooLarge;
    assert(frame.len >= header_size + length);

    const endpoint = &(connection.endpoint orelse return error.ConnectionClosed);
    try writeFrame(endpoint, io, frame, opcode, length);
}

/// Reads one frame. Never writes, so a reader and a writer can drive one connection at once.
///
/// `chunk` is scratch for the walk and is refilled in place; the returned frame owns every
/// byte it carries. On return the stream sits at the next header.
pub fn read(
    connection: *Connection,
    io: Io,
    chunk: []u8,
    timeout: Io.Timeout,
) ReadError!Message {
    assert(chunk.len >= max_frame_size);
    assert(connection.state != .disconnected);

    const endpoint = &(connection.endpoint orelse return error.ConnectionClosed);
    var have = connection.take(chunk);

    const header_deadline = timeout.toDeadline(io);
    while (have < header_size) have += try fill(endpoint, io, chunk[have..], header_deadline);

    const opcode: Opcode = @fromBackingInt(@intCast(std.mem.readInt(u32, chunk[0..4], .little)));
    const length = std.mem.readInt(u32, chunk[4..8], .little);

    // The peer chose this length, so it is refused before any of the payload is read.
    if (length > max_payload_size) return error.FrameTooLarge;

    const frame_size = header_size + length;
    assert(frame_size <= chunk.len);

    const payload_deadline = payload_timeout.toDeadline(io);
    while (have < frame_size) have += try fill(endpoint, io, chunk[have..], payload_deadline);

    connection.pending = have - frame_size;
    connection.pending_at = frame_size;

    const payload = chunk[header_size..][0..length];
    return switch (opcode) {
        .frame => .{ .frame = .{ .frame = try walk(payload), .length = length } },
        .close => .{ .closed = try walk(payload) },
        .ping => .{ .ping = stagePong(chunk, length) },
        .pong => .pong,
        .handshake, _ => error.BadFrame,
    };
}

fn take(connection: *Connection, chunk: []u8) u32 {
    const held = connection.pending;
    if (held == 0) return 0;

    assert(connection.pending_at + held <= chunk.len);
    std.mem.copyForwards(u8, chunk[0..held], chunk[connection.pending_at..][0..held]);

    connection.pending = 0;
    connection.pending_at = 0;
    return held;
}

fn fill(endpoint: *Transport, io: Io, room: []u8, deadline: Io.Timeout) ReadError!u32 {
    assert(room.len > 0);
    assert(deadline != .duration);

    const count = try endpoint.read(io, room, deadline);
    assert(count > 0);
    return @intCast(count);
}

fn walk(payload: []const u8) ReadError!parse.Frame {
    if (payload.len == 0) return error.BadPayload;
    return parse.frame(payload);
}

/// Takes a payload off the wire without looking at it.
fn discardPayload(endpoint: *Transport, io: Io, chunk: []u8, length: u32) ReadError!void {
    var payload: transport.Reader = .init(endpoint, io, payload_timeout, length, chunk);
    return drain(&payload);
}

/// Reads whatever the frame still owes.
fn drain(payload: *transport.Reader) ReadError!void {
    _ = payload.interface.discardRemaining() catch return sourceError(payload);
    assert(payload.remaining == 0);
}

/// What the source's `ReadFailed` stood for; a reader with none recorded ended its stream.
fn sourceError(source: *const transport.Reader) transport.OperationError {
    return source.err orelse error.ConnectionClosed;
}

/// Takes a ping's payload off the wire and lays the answer out in `chunk` behind its own
/// header, ready for one write. Returns how much of it was staged.
fn stagePong(chunk: []u8, length: u32) u32 {
    assert(length <= max_payload_size);
    assert(chunk.len >= header_size + length);

    std.mem.writeInt(u32, chunk[0..4], @backingInt(Opcode.pong), .little);
    std.mem.writeInt(u32, chunk[4..8], length, .little);
    return length;
}

/// Sends the answer `read` laid out in `chunk`, as one write.
pub fn echoPong(connection: *Connection, io: Io, chunk: []u8, length: u32) EchoError!void {
    assert(length <= max_payload_size);
    assert(chunk.len >= header_size + length);

    assert(std.mem.readInt(u32, chunk[0..4], .little) == @backingInt(Opcode.pong));
    assert(std.mem.readInt(u32, chunk[4..8], .little) == length);

    const endpoint = &(connection.endpoint orelse return error.ConnectionClosed);
    return transport.writeAll(endpoint, io, chunk[0 .. header_size + length], payload_timeout);
}

fn writeFrame(
    endpoint: *Transport,
    io: Io,
    frame: []u8,
    opcode: Opcode,
    length: u32,
) transport.OperationError!void {
    assert(length <= max_payload_size);
    assert(frame.len >= header_size + length);

    std.mem.writeInt(u32, frame[0..4], @backingInt(opcode), .little);
    std.mem.writeInt(u32, frame[4..8], length, .little);

    // A frame must arrive as one write; a header and payload sent apart breaks the pipe.
    try transport.writeAll(endpoint, io, frame[0 .. header_size + length], payload_timeout);
}

test "the frame header is little endian, opcode first" {
    var frame: [max_frame_size]u8 = undefined;
    std.mem.writeInt(u32, frame[0..4], @backingInt(Opcode.frame), .little);
    std.mem.writeInt(u32, frame[4..8], 3, .little);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 3, 0, 0, 0 }, frame[0..header_size]);
}

test "the largest handshake the application id permits fits its buffer" {
    const id_bytes = @FieldType(Connection, "application_id").capacity_bytes;
    const application_id: [id_bytes]u8 = @splat(0x01);

    var buffer: [max_handshake_size]u8 = undefined;
    const length = try serialize.handshake(&buffer, std.math.maxInt(u32), &application_id);
    try std.testing.expect(length <= max_handshake_size);
}

test "header and payload capacities agree with the frame size" {
    try std.testing.expectEqual(max_frame_size, header_size + max_payload_size);
}
