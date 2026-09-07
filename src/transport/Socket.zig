//! Unix stream socket at `discord-ipc-N` in the user's runtime directory.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const net = Io.net;

const endpoint = @import("endpoint.zig");
const transport = @import("root.zig");

const Socket = @This();

stream: net.Stream,

pub const OpenError = endpoint.OpenError;

/// Where a sandboxed Discord binds its socket, relative to the runtime directory. The empty
/// entry is a system-wide install and comes first, since it is the common one.
const install_subpaths = [_][]const u8{
    "",
    "app/com.discordapp.Discord/",
    "app/com.discordapp.DiscordCanary/",
    "app/dev.vencord.Vesktop/",
    ".flatpak/com.discordapp.Discord/xdg-run/",
    ".flatpak/dev.vencord.Vesktop/xdg-run/",
    "snap.discord/",
    "snap.discord-canary/",
};

pub fn open(io: Io, environ: *std.process.Environ.Map) OpenError!Socket {
    var directories: [2][]const u8 = undefined;
    const count = runtimeDirectories(environ, &directories);
    assert(count > 0);
    assert(count <= directories.len);

    var path_buffer: [net.UnixAddress.max_len]u8 = undefined;
    for (directories[0..count]) |directory| {
        assert(directory.len > 0);
        for (install_subpaths) |subpath| {
            if (try connectUnder(io, directory, subpath, &path_buffer)) |stream| {
                return .{ .stream = stream };
            }
        }
    }

    return error.NoEndpoint;
}

/// A name too long for a socket address costs that one candidate.
fn connectUnder(
    io: Io,
    directory: []const u8,
    subpath: []const u8,
    path_buffer: []u8,
) Io.Cancelable!?net.Stream {
    const path = std.fmt.bufPrint(path_buffer, "{s}/{s}{s}{c}", .{
        directory,
        subpath,
        endpoint.name_prefix,
        endpoint.digit(0),
    }) catch return null;

    // Every endpoint here shares one directory, so a directory that is not reachable holds
    // none of them and the whole run is settled by asking about it once.
    const holder = path[0 .. path.len - (endpoint.name_prefix.len + 1)];
    Io.Dir.cwd().access(io, holder, .{ .execute = true }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };

    // The name differs from the one before it by its last byte alone.
    const digit_at = path.len - 1;
    assert(path[digit_at] == endpoint.digit(0));

    var number: u32 = 0;
    while (number < endpoint.count) : (number += 1) {
        path_buffer[digit_at] = endpoint.digit(number);
        const address = net.UnixAddress.init(path) catch continue;

        return address.connect(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => continue,
        };
    }

    assert(number == endpoint.count);
    return null;
}

pub fn close(socket: *Socket, io: Io) void {
    socket.stream.close(io);
    socket.* = undefined;
}

/// Answers with whatever has arrived. A fill that wants all of it is `root.readAll`.
pub fn read(
    socket: *Socket,
    io: Io,
    buffer: []u8,
    timeout: Io.Timeout,
) transport.OperationError!usize {
    assert(buffer.len > 0);

    var vector: [1][]u8 = .{buffer};
    const result = try io.operateTimeout(.{ .net_read = .{
        .socket_handle = socket.stream.socket.handle,
        .data = &vector,
    } }, timeout);

    const count = result.net_read catch |err| switch (err) {
        else => return error.ConnectionClosed,
    };
    if (count == 0) return error.ConnectionClosed;

    assert(count <= buffer.len);
    return count;
}

/// Takes as much as the peer will accept now. A write that wants all of it is `root.writeAll`.
pub fn write(
    socket: *Socket,
    io: Io,
    bytes: []const u8,
    timeout: Io.Timeout,
) transport.OperationError!usize {
    assert(bytes.len > 0);

    var vector: [1][]const u8 = .{bytes};
    const result = try io.operateTimeout(.{ .net_write = .{
        .socket_handle = socket.stream.socket.handle,
        .data = &vector,
    } }, timeout);

    const count = result.net_write catch |err| switch (err) {
        else => return error.ConnectionClosed,
    };
    if (count == 0) return error.ConnectionClosed;

    assert(count <= bytes.len);
    return count;
}

pub fn processId() u32 {
    const pid = std.posix.system.getpid();
    assert(pid > 0);
    return @intCast(pid);
}

/// The search order the Discord client itself uses; an empty variable is passed over.
fn runtimeDirectory(environ: *std.process.Environ.Map) []const u8 {
    for ([_][]const u8{ "XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP" }) |name| {
        const directory = environ.get(name) orelse continue;
        if (directory.len > 0) return directory;
    }
    return "/tmp";
}

/// Fills `out` with the directories to search and answers how many.
///
/// Snap confines the *caller*, which moves its `XDG_RUNTIME_DIR` a level below the one Discord
/// binds under, so the parent is searched too.
fn runtimeDirectories(environ: *std.process.Environ.Map, out: *[2][]const u8) u32 {
    const directory = runtimeDirectory(environ);
    assert(directory.len > 0);

    out[0] = directory;
    var count: u32 = 1;

    confined: {
        const snap = environ.get("SNAP") orelse break :confined;
        if (snap.len == 0) break :confined;

        const cut = std.mem.lastIndexOfScalar(u8, directory, '/') orelse break :confined;
        if (cut == 0) break :confined;

        out[1] = directory[0..cut];
        count = 2;
    }

    assert(count > 0);
    assert(count <= out.len);
    return count;
}
