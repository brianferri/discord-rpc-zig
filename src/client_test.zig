const std = @import("std");
const Io = std.Io;

const Client = @import("Client.zig");
const Connection = @import("rpc/Connection.zig");
const transport = @import("transport/root.zig");
const parse = @import("rpc/parse.zig");
const rpc = @import("rpc/root.zig");
const Presence = @import("Presence.zig");
const server_module = @import("transport/server.zig");
const Server = server_module.Server;
const Pair = server_module.Pair;
const Transport = @import("transport/root.zig").Transport;
const User = @import("User.zig");

const application_id = "111111111111111111";

/// A stand-in for the Discord client, framing over whichever transport the target uses.
const Endpoint = struct {
    peer: *Transport,
    buffer: [Connection.max_payload_size]u8 = undefined,

    /// Generous against a loaded machine, and short enough that a frame the client stops
    /// sending ends the test with a failure the suite can report.
    const patience: Io.Timeout = .{ .duration = .{
        .raw = .fromMilliseconds(30 * 1000),
        .clock = .awake,
    } };

    fn readFrame(endpoint: *Endpoint, io: Io) ![]const u8 {
        var header: [Connection.header_size]u8 = undefined;
        try transport.readAll(endpoint.peer, io, &header, patience);
        const length = std.mem.readInt(u32, header[4..8], .little);
        try std.testing.expect(length <= Connection.max_payload_size);
        try transport.readAll(endpoint.peer, io, endpoint.buffer[0..length], patience);
        return endpoint.buffer[0..length];
    }

    fn writeFrame(
        endpoint: *Endpoint,
        io: Io,
        opcode: Connection.Opcode,
        payload: []const u8,
    ) !void {
        var frame: [Connection.max_frame_size]u8 = undefined;
        std.mem.writeInt(u32, frame[0..4], @backingInt(opcode), .little);
        std.mem.writeInt(u32, frame[4..8], @intCast(payload.len), .little);
        @memcpy(frame[Connection.header_size..][0..payload.len], payload);

        try transport.writeAll(
            endpoint.peer,
            io,
            frame[0 .. Connection.header_size + payload.len],
            patience,
        );
    }
};

test "handshake, subscription, presence and events over the wire" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var server = try Server.open(io);
    defer server.close(io);

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try server.advertise(&environ);

    // Heap-placed because a client must not move.
    const client = try gpa.create(Client);
    defer gpa.destroy(client);

    client.init(.{ .application_id = application_id });
    defer client.deinit(io);

    // Recorded before the connection exists, so the handshake's reply is what carries them.
    try client.subscribe(io, .activity_join, "");
    try client.subscribe(io, .message_create, "333333333333333333");

    try client.start(io, &environ);

    var peer = try server.accept(io);
    defer server.disconnect(io, &peer);
    var endpoint: Endpoint = .{ .peer = &peer };

    const handshake = try endpoint.readFrame(io);
    try std.testing.expectEqualStrings(
        \\{"v":1,"client_id":"111111111111111111"}
    , handshake);

    try endpoint.writeFrame(io, .frame,
        \\{"cmd":"DISPATCH","evt":"READY","data":{"user":{"id":"222222222222222222","username":"example","discriminator":"4242","avatar":"a_0f0"}}}
    );

    const subscription = try endpoint.readFrame(io);
    try std.testing.expectEqualStrings(
        \\{"nonce":"1","cmd":"SUBSCRIBE","evt":"ACTIVITY_JOIN"}
    , subscription);

    const scoped = try endpoint.readFrame(io);
    try std.testing.expectEqualStrings(
        \\{"nonce":"2","cmd":"SUBSCRIBE","evt":"MESSAGE_CREATE","args":{"channel_id":"333333333333333333"}}
    , scoped);

    const presence: Presence = .{ .state = "state-1", .instance = true };
    try client.updatePresence(io, &presence);
    const activity = try endpoint.readFrame(io);
    try std.testing.expectEqualStrings(
        \\{"nonce":"3","cmd":"SET_ACTIVITY","args":{"pid":
    , activity[0..48]);
    try std.testing.expect(std.mem.indexOf(u8, activity, "\"state\":\"state-1\"") != null);

    try endpoint.writeFrame(io, .frame,
        \\{"cmd":"DISPATCH","evt":"ACTIVITY_JOIN","data":{"secret":"abcdef01"}}
    );

    var ready_username: User = .empty;
    var join_secret: Client.Secret = .empty;
    var attempt: u32 = 0;
    while (attempt < 200) : (attempt += 1) {
        while (try client.nextEvent(io)) |received| switch (received) {
            .ready => |user| ready_username = user,
            .join_game => |secret| join_secret = secret,
            else => {},
        };
        if (ready_username.username.len > 0 and join_secret.len > 0) break;
        try (Io.Clock.Duration{ .raw = .fromMilliseconds(5), .clock = .awake }).sleep(io);
    }

    try std.testing.expectEqualStrings("example", ready_username.username.slice());
    try std.testing.expectEqualStrings("4242", ready_username.discriminator.slice());
    try std.testing.expectEqualStrings("abcdef01", join_secret.slice());
}

// The request parks its caller until the reply lands, so the endpoint is served from here
// while the command runs beside it.
fn askVoiceSettings(client: *Client, io: Io, out: *anyerror!rpc.VoiceSettings) void {
    out.* = client.voiceSettings(io);
}

test "a voice configuration crosses the wire into the caller's own storage" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var server = try Server.open(io);
    defer server.close(io);

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try server.advertise(&environ);

    const client = try gpa.create(Client);
    defer gpa.destroy(client);

    client.init(.{ .application_id = application_id });
    defer client.deinit(io);

    try client.start(io, &environ);

    var peer = try server.accept(io);
    defer server.disconnect(io, &peer);
    var endpoint: Endpoint = .{ .peer = &peer };

    _ = try endpoint.readFrame(io);
    try endpoint.writeFrame(io, .frame,
        \\{"cmd":"DISPATCH","evt":"READY","data":{"user":{"id":"222222222222222222","username":"example","discriminator":"4242","avatar":"a_0f0"}}}
    );

    var answer: anyerror!rpc.VoiceSettings = rpc.VoiceSettings.empty;
    var asking: Io.Group = .init;
    defer asking.cancel(io);
    try asking.concurrent(io, askVoiceSettings, .{ client, io, &answer });

    const query = try endpoint.readFrame(io);
    try std.testing.expectEqualStrings(
        \\{"nonce":"1","cmd":"GET_VOICE_SETTINGS"}
    , query);

    try endpoint.writeFrame(io, .frame,
        \\{"cmd":"GET_VOICE_SETTINGS","evt":null,"nonce":"1","data":{"input":{"device_id":"mic-1","volume":62.5,"available_devices":[{"id":"mic-1","name":"Microphone"}]},"mode":{"type":"PUSH_TO_TALK","threshold":-45.5},"mute":true}}
    );

    try asking.await(io);
    const settings = try answer;

    try std.testing.expectEqualStrings("mic-1", settings.input.device_id.slice());
    try std.testing.expectEqual(@as(f32, 62.5), settings.input.volume);
    try std.testing.expectEqual(@as(u32, 1), settings.input.device_count);
    try std.testing.expectEqualStrings("Microphone", settings.input.devices[0].name.slice());
    try std.testing.expectEqual(rpc.VoiceSettings.Mode.Kind.push_to_talk, settings.mode.kind);
    try std.testing.expect(settings.mute);
}

test "a presence set before a drop is offered to the next connection" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var server = try Server.open(io);
    defer server.close(io);

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try server.advertise(&environ);

    const client = try gpa.create(Client);
    defer gpa.destroy(client);

    client.init(.{ .application_id = application_id });
    defer client.deinit(io);

    try client.start(io, &environ);

    var peer = try server.accept(io);
    var endpoint: Endpoint = .{ .peer = &peer };

    _ = try endpoint.readFrame(io);
    try endpoint.writeFrame(io, .frame,
        \\{"cmd":"DISPATCH","evt":"READY","data":{"user":{"id":"222222222222222222","username":"example","discriminator":"4242","avatar":"a_0f0"}}}
    );

    const presence: Presence = .{ .state = "state-1" };
    try client.updatePresence(io, &presence);
    const first = try endpoint.readFrame(io);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"state\":\"state-1\"") != null);

    server.disconnect(io, &peer);

    peer = try server.accept(io);
    defer server.disconnect(io, &peer);
    endpoint = .{ .peer = &peer };

    _ = try endpoint.readFrame(io);
    try endpoint.writeFrame(io, .frame,
        \\{"cmd":"DISPATCH","evt":"READY","data":{"user":{"id":"222222222222222222","username":"example","discriminator":"4242","avatar":"a_0f0"}}}
    );

    const restored = try endpoint.readFrame(io);
    try std.testing.expect(std.mem.indexOf(u8, restored, "\"state\":\"state-1\"") != null);
}

// The peer supplies the length, so this guard stands between it and the read buffer.
// A read takes whatever the endpoint has, so two frames in one write arrive together and the
// second must be answered from what the first left behind.
test "frames arriving together are read one at a time" {
    const io = std.testing.io;

    var pair: Pair = undefined;
    try pair.open(io, std.testing.allocator);
    defer pair.close(io);

    var connection: Connection = .init(application_id);
    defer connection.deinit(io);
    connection.endpoint = pair.transport;
    connection.state = .connected;

    const first =
        \\{"cmd":"DISPATCH","evt":"ACTIVITY_JOIN","data":{"secret":"first"}}
    ;
    const second =
        \\{"cmd":"DISPATCH","evt":"ACTIVITY_SPECTATE","data":{"secret":"second"}}
    ;

    // One write, so the endpoint holds both before either is asked for.
    var both: [512]u8 = undefined;
    var end: usize = 0;
    for ([_][]const u8{ first, second }) |payload| {
        std.mem.writeInt(u32, both[end..][0..4], @backingInt(Connection.Opcode.frame), .little);
        std.mem.writeInt(u32, both[end..][4..8], @intCast(payload.len), .little);
        @memcpy(both[end + Connection.header_size ..][0..payload.len], payload);
        end += Connection.header_size + payload.len;
    }
    try transport.writeAll(&pair.peer, io, both[0..end], .none);

    var chunk: [Connection.max_frame_size]u8 = undefined;

    const one = try connection.read(io, &chunk, .none);
    try std.testing.expectEqualStrings("ACTIVITY_JOIN", one.frame.frame.event.slice());
    try std.testing.expectEqualStrings("first", one.frame.frame.secret.slice());
    try std.testing.expect(connection.pending > 0);

    const two = try connection.read(io, &chunk, .none);
    try std.testing.expectEqualStrings("ACTIVITY_SPECTATE", two.frame.frame.event.slice());
    try std.testing.expectEqualStrings("second", two.frame.frame.secret.slice());
    try std.testing.expectEqual(@as(u32, 0), connection.pending);
}

// A frame arriving in pieces is still one wait, so the deadline is resolved before the first
// piece and not renewed by each one that follows.
test "a frame fed in pieces is bounded from the first of them" {
    const io = std.testing.io;

    var pair: Pair = undefined;
    try pair.open(io, std.testing.allocator);
    defer pair.close(io);

    var connection: Connection = .init(application_id);
    defer connection.deinit(io);
    connection.endpoint = pair.transport;
    connection.state = .connected;

    const payload =
        \\{"cmd":"DISPATCH","evt":"ACTIVITY_JOIN","data":{"secret":"dribbled"}}
    ;

    var framed: [256]u8 = undefined;
    std.mem.writeInt(u32, framed[0..4], @backingInt(Connection.Opcode.frame), .little);
    std.mem.writeInt(u32, framed[4..8], @intCast(payload.len), .little);
    @memcpy(framed[Connection.header_size..][0..payload.len], payload);
    const end = Connection.header_size + payload.len;

    // Three bytes at a time, so the header alone spans several reads and the payload more.
    var sent: usize = 0;
    while (sent < end) {
        const piece = @min(3, end - sent);
        try transport.writeAll(&pair.peer, io, framed[sent..][0..piece], .none);
        sent += piece;
    }

    var chunk: [Connection.max_frame_size]u8 = undefined;

    const message = try connection.read(io, &chunk, .none);
    try std.testing.expectEqualStrings("dribbled", message.frame.frame.secret.slice());
    try std.testing.expectEqual(@as(u32, 0), connection.pending);
}

test "a frame claiming more than the payload capacity is refused" {
    const io = std.testing.io;

    var pair: Pair = undefined;
    try pair.open(io, std.testing.allocator);
    defer pair.close(io);

    var connection: Connection = .init(application_id);
    defer connection.deinit(io);
    connection.endpoint = pair.transport;
    connection.state = .sent_handshake;

    var header: [Connection.header_size]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @backingInt(Connection.Opcode.frame), .little);
    std.mem.writeInt(u32, header[4..8], Connection.max_payload_size + 1, .little);
    try transport.writeAll(&pair.peer, io, &header, .none);

    var chunk: [Connection.max_frame_size]u8 = undefined;
    try std.testing.expectError(
        error.FrameTooLarge,
        connection.read(io, &chunk, .none),
    );
}

// A ping's payload left on the wire would be read as the following header.
test "a ping's payload is taken off the wire whether or not it is echoed" {
    const io = std.testing.io;

    var pair: Pair = undefined;
    try pair.open(io, std.testing.allocator);
    defer pair.close(io);

    var connection: Connection = .init(application_id);
    defer connection.deinit(io);
    connection.endpoint = pair.transport;
    connection.state = .connected;

    var header: [Connection.header_size]u8 = undefined;
    const ping_body = "PING-PAYLOAD";
    std.mem.writeInt(u32, header[0..4], @backingInt(Connection.Opcode.ping), .little);
    std.mem.writeInt(u32, header[4..8], ping_body.len, .little);
    try transport.writeAll(&pair.peer, io, &header, .none);
    try transport.writeAll(&pair.peer, io, ping_body, .none);

    const close_body =
        \\{"code":1000,"message":"bye"}
    ;
    std.mem.writeInt(u32, header[0..4], @backingInt(Connection.Opcode.close), .little);
    std.mem.writeInt(u32, header[4..8], close_body.len, .little);
    try transport.writeAll(&pair.peer, io, &header, .none);
    try transport.writeAll(&pair.peer, io, close_body, .none);

    var chunk: [Connection.max_frame_size]u8 = undefined;

    const ping = try connection.read(io, &chunk, .none);
    try std.testing.expectEqual(@as(u32, ping_body.len), ping.ping);
    try std.testing.expectEqualStrings(ping_body, chunk[Connection.header_size..][0..ping.ping]);

    // The answer is laid out ready to send, and this caller never sends it.
    try std.testing.expectEqual(
        @as(u32, @backingInt(Connection.Opcode.pong)),
        std.mem.readInt(u32, chunk[0..4], .little),
    );

    const closed = try connection.read(io, &chunk, .none);
    try std.testing.expectEqual(@as(i32, 1000), closed.closed.code);
}

test "an unexpected opcode is rejected" {
    const io = std.testing.io;

    var pair: Pair = undefined;
    try pair.open(io, std.testing.allocator);
    defer pair.close(io);

    var connection: Connection = .init(application_id);
    defer connection.deinit(io);
    connection.endpoint = pair.transport;
    connection.state = .connected;

    var header: [Connection.header_size]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @backingInt(Connection.Opcode.handshake), .little);
    std.mem.writeInt(u32, header[4..8], 0, .little);
    try transport.writeAll(&pair.peer, io, &header, .none);

    var chunk: [Connection.max_frame_size]u8 = undefined;
    try std.testing.expectError(error.BadFrame, connection.read(io, &chunk, .none));
}
