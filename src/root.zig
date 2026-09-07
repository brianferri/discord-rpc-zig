//! A Zig client for Discord's local Rich Presence IPC.
//!
//! It connects to the Discord desktop client over its local endpoint, reports what the player
//! is doing, and carries the events and commands the RPC protocol defines back and forth.
//!
//! | System  | Endpoint                    |
//! | ------- | --------------------------- |
//! | Linux   | unix socket                 |
//! | macOS   | unix socket                 |
//! | Windows | named pipe, through `ntdll` |
//!
//! An application id comes from the
//! [Discord developer site](https://discord.com/developers/applications).
//!
//! ---
//!
//! ## A client
//!
//! ```zig
//! const discord = @import("discord_rpc");
//!
//! pub fn main(init: std.process.Init) !void {
//!     const client = try init.gpa.create(discord.Client);
//!     defer init.gpa.destroy(client);
//!
//!     client.init(.{ .application_id = "your application id" });
//!     defer client.deinit(init.io);
//!
//!     try client.subscribe(init.io, .activity_join, "");
//!     try client.subscribe(init.io, .activity_join_request, "");
//!
//!     try client.start(init.io, init.environ_map);
//!
//!     while (running) {
//!         try client.updatePresence(init.io, &.{ .state = "In the lobby" });
//!
//!         while (try client.nextEvent(init.io)) |event| switch (event) {
//!             .ready => |user| std.log.info("connected as {s}", .{user.username.slice()}),
//!             .join_request => |user| try client.respond(init.io, user.id.slice(), .yes),
//!             else => {},
//!         };
//!     }
//! }
//! ```
//!
//! - `Client.start` runs a **reader** task and a **writer** task on the `Io` it is given, and
//!   reconnects on its own for as long as it runs.
//! - `Client.stop` pauses both and keeps everything else, so a later `start` resumes without
//!   rebuilding the client.
//! - Every entry point is safe to call from any task.
//!
//! ---
//!
//! ## Presence
//!
//! ```zig
//! try client.updatePresence(io, &.{
//!     .state = "In a match",
//!     .details = "Ranked, round 3",
//!     .start_timestamp = std.Io.Clock.real.now(io).toSeconds(),
//!     .large_image_key = "map-harbour",
//!     .party_id = "party-1",
//!     .party_size = 3,
//!     .party_max = 5,
//!     .party_privacy = .public,
//!     .join_secret = "a secret only your game understands",
//!
//!     // A link opens when the player taps the line or the image it hangs on, and
//!     // `status_display` picks the line the member list shows.
//!     .details_url = "https://example.com/matches/42",
//!     .large_image_url = "https://example.com/maps/harbour",
//!     .status_display = .details,
//! });
//!
//! try client.clearPresence(io);
//! ```
//!
//! A presence is kept and offered again on the next connection, so a reconnect needs nothing
//! from the caller.
//!
//! ---
//!
//! ## Memory
//!
//! Nothing here allocates. A client holds every buffer it will ever use as part of itself,
//! under a ceiling asserted at compile time as `Client.max_footprint_bytes`.
//!
//! > A client's queues point into its own storage. Place one in static storage or on the heap
//! > and leave it where it is.
//!
//! The example above puts one on the heap. Static storage does as well:
//!
//! ```zig
//! var client: discord.Client = undefined;
//!
//! pub fn main(init: std.process.Init) !void {
//!     client.init(.{ .application_id = "your application id" });
//!     defer client.deinit(init.io);
//!
//!     try client.start(init.io, init.environ_map);
//! }
//! ```
//!
//! The two tasks `start` spawns take their stacks from the `Io`. `std.Io.Threaded` reserves
//! 16 MiB per thread by default, which dwarfs the client itself; size it through its own
//! options where that matters.
//!
//! ---
//!
//! ## Events
//!
//! `Client.subscribe` names one event from `rpc.Event` and the object it is watched on, which
//! `rpc.Event.scope` gives:
//!
//! ```zig
//! try client.subscribe(io, .activity_join, "");           // global, so no key
//! try client.subscribe(io, .guild_status, guild_id);      // keyed by a guild
//! try client.subscribe(io, .message_create, channel_id);  // keyed by a channel
//!
//! try client.unsubscribe(io, .message_create, channel_id);
//! ```
//!
//! A subscription made before the client connects is carried by the first connection, and a
//! reconnect carries the whole set again.
//!
//! `Client.nextEvent` takes what has been recorded, one at a time, on the calling thread;
//! `Client.waitEvent` sleeps until there is something to take:
//!
//! ```zig
//! while (try client.nextEvent(io)) |event| switch (event) {
//!     .ready => |user| std.log.info("connected as {s}", .{user.username.slice()}),
//!     .join_game => |secret| joinLobby(secret.slice()),
//!     .join_request => |user| try client.respond(io, user.id.slice(), .yes),
//!     .errored => |status| std.log.warn("{d}: {s}", .{ status.code, status.message.slice() }),
//!
//!     else => {},
//! };
//! ```
//!
//! The three activity events have variants of their own. The rest arrive as a `notice`, which
//! names the event and carries what it came with; `rpc.Event.shape` says which member of
//! `rpc.Payload` an event fills, so the two can never disagree:
//!
//! ```zig
//! .notice => |notice| switch (notice.payload) {
//!     .message => |message| std.log.info("{s}: {s}", .{
//!         message.author.username.slice(),
//!         message.content.slice(),
//!     }),
//!     .speaking => |speaking| markSpeaking(speaking.user_id.slice()),
//!     .voice_channel => |selected| std.log.info("moved to {s}", .{selected.channel_id.slice()}),
//!
//!     // A voice settings change says only that it happened, since the settings are wider
//!     // than an event queue carries. `voiceSettings` reads them back.
//!     .none => std.log.debug("{s}", .{notice.event.name()}),
//!     else => {},
//! },
//! ```
//!
//! ---
//!
//! ## Commands
//!
//! Beyond presence, a client speaks the commands that need an answer back:
//!
//! | Commands                                                          | For                   |
//! | ----------------------------------------------------------------- | --------------------- |
//! | `authorize`, `authenticate`                                       | the OAuth2 handshake  |
//! | `voiceSettings`, `setVoiceSettings`                               | voice configuration   |
//! | `setUserVoiceSettings`                                            | one user's mix        |
//! | `setCertifiedDevices`                                             | certified devices     |
//! | `guilds`, `guild`, `channels`, `channel`                          | what the user can see |
//! | `selectVoiceChannel`, `selectTextChannel`, `selectedVoiceChannel` | where the user is     |
//!
//! Each parks its caller until Discord replies or `Client.request_timeout_ms` passes, and
//! `Client.request_capacity` bounds how many may wait at once.
//!
//! ```zig
//! const settings = try client.voiceSettings(io);
//! for (settings.input.devices[0..settings.input.device_count]) |device| {
//!     std.log.info("input: {s}", .{device.name.slice()});
//! }
//!
//! _ = try client.setVoiceSettings(io, &.{ .mute = true, .input_volume = 80 });
//! ```
//!
//! A reply wider than a frame record is walked into storage the caller passes in, which is why
//! a client's own footprint stays the same whatever it is told:
//!
//! ```zig
//! var listed: discord.rpc.GuildList = .empty;
//! try client.guilds(io, &listed);
//! for (listed.guilds[0..listed.count]) |guild| {
//!     std.log.info("{s}", .{guild.name.slice()});
//! }
//!
//! var joined: discord.rpc.Channel = .empty;
//! try client.selectVoiceChannel(io, channel_id, .{ .force = true }, &joined);
//! if (joined.found) std.log.info("in {s}", .{joined.name.slice()});
//! ```
//!
//! Every list is bounded by a named capacity, and what Discord offers past one is dropped with
//! a count saying how many were kept.
//!
//! ---
//!
//! ## Launching from an invite
//!
//! `register.handler` claims the `discord-<application_id>://` scheme, which is how Discord
//! launches a game from an invite, and `register.steamGame` claims it for a game Steam
//! launches. Both stand alone, so the scheme can be claimed without opening a client.
//!
//! ```zig
//! try discord.register.handler(io, environ, application_id, null);
//! try discord.register.steamGame(io, environ, application_id, "your steam id");
//! ```
//!
//! ## Other languages
//!
//! `zig build` also emits `discord-rpc-c`, a C ABI over the same client,
//! [documented beside this](c/). `examples/presence.lua` drives it from LuaJIT.

const timeout = @import("timeout.zig");

pub const Backoff = @import("Backoff.zig");
pub const Client = @import("Client.zig");
pub const json = @import("json/root.zig");
pub const Presence = @import("Presence.zig");
pub const User = @import("User.zig");
pub const register = @import("register/root.zig");
pub const rpc = @import("rpc/root.zig");
pub const text = @import("text.zig");
pub const transport = @import("transport/root.zig");

pub const milliseconds = timeout.milliseconds;

test {
    _ = User;
    _ = Client;
    _ = Backoff;
    _ = Presence;

    _ = json;
    _ = rpc;
    _ = text;
    _ = timeout;
    _ = register;
    _ = transport;

    _ = @import("fuzz_test.zig");
    _ = @import("client_test.zig");
    _ = @import("transport_test.zig");
    _ = @import("rpc/parse_stream_test.zig");
}
