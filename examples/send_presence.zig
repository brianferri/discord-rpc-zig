//! A counter whose value is reported to Discord as a presence.
//!
//! Commands: `q` quits, `t` shuts the client down, `y` starts it again, `c` toggles the
//! presence off and on, and anything else advances the counter.

const std = @import("std");
const Io = std.Io;
const discord = @import("discord_rpc");

const application_id = "111111111111111111";

const Game = struct {
    client: *discord.Client,
    stdin: *Io.Reader,
    stdout: *Io.Writer,
    start_timestamp: i64,
    counter: u32 = 0,
    sending_presence: bool = true,
    running: bool = true,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const environ = init.environ_map;

    // A client owns every buffer it uses, so it is too large for a stack.
    const client = try init.gpa.create(discord.Client);
    defer init.gpa.destroy(client);

    client.init(.{ .application_id = application_id });
    defer client.deinit(io);

    // The three a game is invited through; the rest of the catalogue is keyed by a guild or a
    // channel this example has none of.
    try client.subscribe(io, .activity_join, "");
    try client.subscribe(io, .activity_spectate, "");
    try client.subscribe(io, .activity_join_request, "");

    // Claiming the handler is unrelated to connecting, so a failure still starts the client.
    discord.register.handler(io, environ, application_id, null) catch |err| {
        std.log.warn("could not register the discord-{s}:// handler: {t}", .{
            application_id,
            err,
        });
    };

    var stdin_buffer: [512]u8 = undefined;
    var stdout_buffer: [512]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &stdin_buffer);
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);

    var game: Game = .{
        .client = client,
        .stdin = &stdin_reader.interface,
        .stdout = &stdout_writer.interface,
        .start_timestamp = Io.Clock.real.now(io).toSeconds(),
    };

    try client.start(io, environ);

    try game.stdout.writeAll("Type anything to advance the counter, or q to quit.\n");
    while (game.running) {
        var line_buffer: [512]u8 = undefined;
        const line = try prompt(&game, &line_buffer);
        try command(&game, io, environ, line);
        while (try client.nextEvent(io)) |event| try report(&game, io, &event);
    }
}

fn command(game: *Game, io: Io, environ: *std.process.Environ.Map, line: []const u8) !void {
    if (line.len == 0) return;

    switch (line[0]) {
        'q' => {
            game.running = false;
            return;
        },
        't' => {
            if (!game.client.isRunning()) return game.stdout.writeAll("Discord is already off.\n");
            try game.stdout.writeAll("Shutting off Discord.\n");
            game.client.stop(io);
            return;
        },
        'y' => {
            if (game.client.isRunning()) return game.stdout.writeAll("Discord is already on.\n");
            try game.stdout.writeAll("Starting Discord again.\n");
            return game.client.start(io, environ);
        },
        'c' => {
            game.sending_presence = !game.sending_presence;
            try game.stdout.writeAll(if (game.sending_presence)
                "Restoring presence information.\n"
            else
                "Clearing presence information.\n");
            return sendPresence(game, io);
        },
        else => {},
    }

    game.counter += 1;
    try game.stdout.print("Counter is now {d}.\n", .{game.counter});
    return sendPresence(game, io);
}

fn report(game: *Game, io: Io, event: *const discord.Client.Event) !void {
    switch (event.*) {
        .ready => |user| try game.stdout.print("\nDiscord: connected to {s}#{s} - {s}\n", .{
            user.username.slice(),
            user.discriminator.slice(),
            user.id.slice(),
        }),
        .disconnected => |status| try game.stdout.print("\nDiscord: disconnected ({d}: {s})\n", .{
            status.code,
            status.message.slice(),
        }),
        .errored => |status| try game.stdout.print("\nDiscord: error ({d}: {s})\n", .{
            status.code,
            status.message.slice(),
        }),
        .join_game => |secret| try game.stdout.print("\nDiscord: join ({s})\n", .{secret.slice()}),
        .spectate_game => |secret| try game.stdout.print(
            "\nDiscord: spectate ({s})\n",
            .{secret.slice()},
        ),
        .join_request => |user| try answerJoinRequest(game, io, user),
        .notice => |*notice| try reportNotice(game, notice),
    }
}

/// Each event names what it arrived with, so the few this example has something to say about
/// say it, and the rest report the name alone.
fn reportNotice(game: *Game, notice: *const discord.Client.Notice) !void {
    const name = notice.event.name();
    switch (notice.payload) {
        .message => |message| try game.stdout.print("\nDiscord: {s} from {s}: {s}\n", .{
            name,
            message.author.username.slice(),
            message.content.slice(),
        }),
        .notification => |notification| try game.stdout.print("\nDiscord: {s} - {s}\n", .{
            notification.title.slice(),
            notification.body.slice(),
        }),
        .speaking => |speaking| try game.stdout.print("\nDiscord: {s} {s}\n", .{
            name,
            speaking.user_id.slice(),
        }),
        .guild => |guild| try game.stdout.print("\nDiscord: {s} {s}\n", .{
            name,
            guild.name.slice(),
        }),
        .channel => |channel| try game.stdout.print("\nDiscord: {s} {s}\n", .{
            name,
            channel.name.slice(),
        }),
        else => try game.stdout.print("\nDiscord: {s}\n", .{name}),
    }
}

fn answerJoinRequest(game: *Game, io: Io, user: discord.User) !void {
    try game.stdout.print("\nDiscord: join request from {s}#{s} - {s}\nAccept? (y/n) ", .{
        user.username.slice(),
        user.discriminator.slice(),
        user.id.slice(),
    });
    try game.stdout.flush();

    const answer = (try game.stdin.takeDelimiter('\n')) orelse return;
    const reply: discord.Client.Reply = switch (if (answer.len > 0) answer[0] else 'n') {
        'y' => .yes,
        else => .no,
    };
    return game.client.respond(io, user.id.slice(), reply);
}

fn sendPresence(game: *Game, io: Io) !void {
    if (!game.sending_presence) return game.client.clearPresence(io);

    var details_buffer: [64]u8 = undefined;
    const details = try std.fmt.bufPrint(&details_buffer, "Counter: {d}", .{game.counter});

    const presence: discord.Presence = .{
        .state = "state-1",
        .details = details,
        .start_timestamp = game.start_timestamp,
        .end_timestamp = Io.Clock.real.now(io).toSeconds() + 5 * 60,
        .large_image_key = "image-1",
        .small_image_key = "image-2",
        .party_id = "party-1",
        .party_size = 1,
        .party_max = 6,
        .party_privacy = .public,
        .match_secret = "abcdef01",
        .join_secret = "abcdef02",
        .spectate_secret = "abcdef03",
    };
    return game.client.updatePresence(io, &presence);
}

fn prompt(game: *Game, buffer: []u8) ![]const u8 {
    try game.stdout.writeAll("\n> ");
    try game.stdout.flush();

    const line = (try game.stdin.takeDelimiter('\n')) orelse {
        game.running = false;
        return "";
    };

    const length = @min(line.len, buffer.len);
    @memcpy(buffer[0..length], line[0..length]);
    return buffer[0..length];
}
