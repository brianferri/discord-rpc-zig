//! The endpoint's own side of the local IPC, for driving a client over the real
//! transport. Serves endpoint zero.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const net = Io.net;
const windows = std.os.windows;

const endpoint = @import("endpoint.zig");

/// The far end of the same connection the client holds. Torn down by the server.
pub const Peer = @import("root.zig").Transport;

pub const Server = switch (endpoint.family) {
    .socket => Socket,
    .pipe => Pipe,
};

/// Both ends of one connection. `close` gives up the endpoint's side alone; `transport` is
/// the caller's to close, and only once.
pub const Pair = struct {
    server: Server,
    transport: Peer,
    peer: Peer,

    pub fn open(pair: *Pair, io: Io, gpa: std.mem.Allocator) !void {
        pair.server = try Server.open(io);
        errdefer pair.server.close(io);

        var environ: std.process.Environ.Map = .init(gpa);
        defer environ.deinit();
        try pair.server.advertise(&environ);

        pair.transport = try Peer.open(io, &environ);
        errdefer pair.transport.close(io);

        pair.peer = try pair.server.accept(io);
    }

    pub fn close(pair: *Pair, io: Io) void {
        pair.server.disconnect(io, &pair.peer);
        pair.server.close(io);
    }
};

/// A unix socket in a directory of its own, which `advertise` names as the runtime directory.
const Socket = struct {
    listener: net.Server,
    directory: [directory_capacity]u8,
    directory_length: u8,

    /// Long enough for the prefix and a hexadecimal `u64`.
    const directory_capacity = 48;

    pub fn open(io: Io) !Socket {
        var server: Socket = .{
            .listener = undefined,
            .directory = @splat(0),
            .directory_length = 0,
        };

        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);
        const directory = try std.fmt.bufPrint(&server.directory, "/tmp/discord-rpc-zig-{x}", .{
            std.mem.readInt(u64, &random_bytes, .little),
        });
        assert(directory.len < directory_capacity);
        server.directory_length = @intCast(directory.len);
        try Io.Dir.cwd().createDirPath(io, directory);

        var path_buffer: [net.UnixAddress.max_len]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}{c}", .{
            directory,
            endpoint.name_prefix,
            endpoint.digit(0),
        });
        const address = try net.UnixAddress.init(path);
        server.listener = try address.listen(io, .{});
        return server;
    }

    pub fn close(server: *Socket, io: Io) void {
        server.listener.deinit(io);

        // The directory carries a random name under /tmp, so one left behind by a failed
        // delete is inert and the system reclaims it.
        Io.Dir.cwd().deleteTree(io, server.directory[0..server.directory_length]) catch {};

        server.* = undefined;
    }

    pub fn advertise(server: *const Socket, environ: *std.process.Environ.Map) !void {
        assert(server.directory_length > 0);
        try environ.put("XDG_RUNTIME_DIR", server.directory[0..server.directory_length]);
    }

    pub fn accept(server: *Socket, io: Io) !Peer {
        return .{ .stream = try server.listener.accept(io) };
    }

    pub fn disconnect(server: *Socket, io: Io, peer: *Peer) void {
        assert(server.directory_length > 0);
        peer.close(io);
    }
};

/// A named pipe instance. The name is global, so `open` returns `error.SkipZigTest` when
/// another client already holds endpoint zero.
const Pipe = struct {
    handle: windows.HANDLE,
    /// For this end's own controls; the peer gets one of its own.
    event: windows.HANDLE,
    listening: bool,

    const path = std.unicode.utf8ToUtf16LeStringLiteral(
        endpoint.pipe_path_prefix ++ .{endpoint.digit(0)},
    );

    /// A frame's worth of room in each direction.
    const quota_bytes: u32 = 64 * 1024;

    pub fn open(io: Io) !Pipe {
        _ = io;

        var name: windows.UNICODE_STRING = .init(path);
        const attributes = Peer.objectAttributes(&name);

        // Negative is relative, and hundred-nanosecond units: fifty milliseconds.
        const default_timeout: windows.LARGE_INTEGER = -500_000;

        var handle: windows.HANDLE = undefined;
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        return switch (windows.ntdll.NtCreateNamedPipeFile(
            &handle,
            .{
                .GENERIC = .{ .READ = true, .WRITE = true },
                .STANDARD = .{ .SYNCHRONIZE = true },
            },
            &attributes,
            &io_status_block,
            .{ .READ = true, .WRITE = true },
            .CREATE,
            .{ .IO = .ASYNCHRONOUS },
            // Discord's endpoint is byte-oriented; the framing layer depends on it.
            .{ .TYPE = .BYTE_STREAM },
            .{ .MODE = .BYTE_STREAM },
            .{ .OPERATION = .QUEUE },
            1,
            quota_bytes,
            quota_bytes,
            &default_timeout,
        )) {
            .SUCCESS => .{
                .handle = handle,
                .event = try Peer.createEvent(),
                .listening = false,
            },
            // Another client of this machine holds the only endpoint zero.
            .OBJECT_NAME_COLLISION, .INSTANCE_NOT_AVAILABLE, .PIPE_BUSY => error.SkipZigTest,
            else => error.Unavailable,
        };
    }

    pub fn close(server: *Pipe, io: Io) void {
        _ = io;
        windows.CloseHandle(server.handle);
        windows.CloseHandle(server.event);
        server.* = undefined;
    }

    pub fn advertise(server: *const Pipe, environ: *std.process.Environ.Map) !void {
        // The name is fixed in the NT object namespace.
        _ = server;
        _ = environ;
    }

    pub fn accept(server: *Pipe, io: Io) !Peer {
        _ = io;
        assert(!server.listening);

        switch (server.control(windows.CTL_CODE.PIPE.LISTEN)) {
            // A client that connected before the listen began is already accepted.
            .SUCCESS, .PIPE_CONNECTED => {},
            else => return error.ConnectionClosed,
        }

        server.listening = true;
        return .{
            .handle = server.handle,
            .read_event = try Peer.createEvent(),
            .write_event = try Peer.createEvent(),
        };
    }

    /// The peer shares the server's handle, which outlives it; only its events are its own.
    pub fn disconnect(server: *Pipe, io: Io, peer: *Peer) void {
        _ = io;
        assert(server.listening);
        assert(peer.handle == server.handle);

        windows.CloseHandle(peer.read_event);
        windows.CloseHandle(peer.write_event);
        _ = server.control(windows.CTL_CODE.PIPE.DISCONNECT);
        server.listening = false;
        peer.* = undefined;
    }

    fn control(server: *Pipe, code: windows.CTL_CODE) windows.NTSTATUS {
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        const status = windows.ntdll.NtFsControlFile(
            server.handle,
            server.event,
            null,
            null,
            &io_status_block,
            code,
            null,
            0,
            null,
            0,
        );
        if (status != .PENDING) return status;

        return switch (windows.ntdll.NtWaitForSingleObject(server.event, .FALSE, null)) {
            .SUCCESS => io_status_block.u.Status,
            else => |wait| wait,
        };
    }
};
