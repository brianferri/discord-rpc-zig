//! The transport on its own, against the endpoint that stands in for Discord.

const std = @import("std");
const Io = std.Io;

const transport = @import("transport/root.zig");
const Pair = @import("transport/server.zig").Pair;
const endpoint = @import("transport/endpoint.zig");
const Transport = transport.Transport;

test "bytes travel in both directions" {
    const io = std.testing.io;

    var pair: Pair = undefined;
    try pair.open(io, std.testing.allocator);
    defer pair.close(io);
    defer pair.transport.close(io);

    try transport.writeAll(&pair.transport, io, "from the client", .none);
    var inbound: [15]u8 = undefined;
    try transport.readAll(&pair.peer, io, &inbound, .none);
    try std.testing.expectEqualStrings("from the client", &inbound);

    try transport.writeAll(&pair.peer, io, "from the endpoint", .none);
    var outbound: [17]u8 = undefined;
    try transport.readAll(&pair.transport, io, &outbound, .none);
    try std.testing.expectEqualStrings("from the endpoint", &outbound);
}

test "a fill spanning several writes is one read" {
    const io = std.testing.io;

    var pair: Pair = undefined;
    try pair.open(io, std.testing.allocator);
    defer pair.close(io);
    defer pair.transport.close(io);

    try transport.writeAll(&pair.peer, io, "abcd", .none);
    try transport.writeAll(&pair.peer, io, "efgh", .none);

    var whole: [8]u8 = undefined;
    try transport.readAll(&pair.transport, io, &whole, .none);
    try std.testing.expectEqualStrings("abcdefgh", &whole);
}

test "a read carrying a deadline reports reaching it" {
    const io = std.testing.io;

    var pair: Pair = undefined;
    try pair.open(io, std.testing.allocator);
    defer pair.close(io);
    defer pair.transport.close(io);

    var unread: [1]u8 = undefined;
    const deadline: Io.Timeout = .{
        .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake },
    };
    try std.testing.expectError(
        error.Timeout,
        transport.readAll(&pair.transport, io, &unread, deadline),
    );

    try transport.writeAll(&pair.peer, io, "x", .none);
    try transport.readAll(&pair.transport, io, &unread, .none);
    try std.testing.expectEqualStrings("x", &unread);
}

test "a deadline that has not passed does not cut a read short" {
    const io = std.testing.io;

    var pair: Pair = undefined;
    try pair.open(io, std.testing.allocator);
    defer pair.close(io);
    defer pair.transport.close(io);

    try transport.writeAll(&pair.peer, io, "soon", .none);
    var arrived: [4]u8 = undefined;
    try transport.readAll(&pair.transport, io, &arrived, .{
        .duration = .{ .raw = .fromMilliseconds(10_000), .clock = .awake },
    });
    try std.testing.expectEqualStrings("soon", &arrived);
}

test "a closed peer ends a read" {
    const io = std.testing.io;

    var pair: Pair = undefined;
    try pair.open(io, std.testing.allocator);

    pair.server.disconnect(io, &pair.peer);

    var unread: [1]u8 = undefined;
    try std.testing.expectError(
        error.ConnectionClosed,
        transport.readAll(&pair.transport, io, &unread, .none),
    );

    pair.transport.close(io);
    pair.server.close(io);
}

// A sandboxed Discord binds below the runtime directory, so the search has to descend.
test "an endpoint under a sandbox layout is found" {
    if (endpoint.family != .socket) return error.SkipZigTest;
    const io = std.testing.io;

    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    var root_buffer: [64]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, "/tmp/discord-rpc-zig-sandbox-{x}", .{
        std.mem.readInt(u64, &random_bytes, .little),
    });

    var path_buffer: [Io.net.UnixAddress.max_len]u8 = undefined;
    const nested = try std.fmt.bufPrint(&path_buffer, "{s}/snap.discord", .{root});
    try Io.Dir.cwd().createDirPath(io, nested);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};

    const path = try std.fmt.bufPrint(&path_buffer, "{s}/snap.discord/{s}{c}", .{
        root,
        endpoint.name_prefix,
        endpoint.digit(0),
    });
    const address = try Io.net.UnixAddress.init(path);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);

    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("XDG_RUNTIME_DIR", root);

    var opened = try Transport.open(io, &environ);
    defer opened.close(io);

    var accepted: Transport = .{ .stream = try listener.accept(io) };
    defer accepted.close(io);

    try transport.writeAll(&accepted, io, "under a sandbox", .none);
    var arrived: [15]u8 = undefined;
    try transport.readAll(&opened, io, &arrived, .none);
    try std.testing.expectEqualStrings("under a sandbox", &arrived);
}

// The `sandbox` compose service advertises a layout in a real runtime directory.
test "the layout the environment advertises is found" {
    if (endpoint.family != .socket) return error.SkipZigTest;
    const io = std.testing.io;

    var advertised = try std.testing.environ.createMap(std.testing.allocator);
    defer advertised.deinit();

    const layout = advertised.get("DISCORD_RPC_SANDBOX_LAYOUT") orelse return error.SkipZigTest;
    const runtime = advertised.get("XDG_RUNTIME_DIR") orelse return error.SkipZigTest;

    var path_buffer: [Io.net.UnixAddress.max_len]u8 = undefined;
    const nested = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ runtime, layout });
    try Io.Dir.cwd().createDirPath(io, nested);

    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}/{s}{c}", .{
        runtime,
        layout,
        endpoint.name_prefix,
        endpoint.digit(0),
    });
    const address = try Io.net.UnixAddress.init(path);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);

    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("XDG_RUNTIME_DIR", runtime);

    var opened = try Transport.open(io, &environ);
    defer opened.close(io);

    var accepted: Transport = .{ .stream = try listener.accept(io) };
    defer accepted.close(io);

    try transport.writeAll(&accepted, io, "advertised", .none);
    var arrived: [10]u8 = undefined;
    try transport.readAll(&opened, io, &arrived, .none);
    try std.testing.expectEqualStrings("advertised", &arrived);
}
