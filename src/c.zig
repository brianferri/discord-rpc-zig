//! The C ABI over the same client. A foreign caller has no `Io` to give, so each client owns
//! one, along with the threads that drive it. A Zig caller uses `Client` directly and threads
//! its own `Io` through, which [the library's own documentation](../) covers.
//!
//! > There is no header to ship. The `extern struct`s and the status enums here are the
//! > declarations a caller transcribes, and their values, field order and array sizes are all
//! > part of the contract.
//!
//! ---
//!
//! ## Statuses
//!
//! `discord_client_init` and `discord_client_start` answer an `InitStatus`; everything else
//! answers a `ClientStatus`. Zero is success in both.
//!
//! `init` overwrites the handle, and every other call checks it first:
//!
//! ```c
//! DiscordClient client;
//! discord_client_init(&client, "your application id", NULL, false, NULL);   /* 0 */
//!
//! discord_client_deinit(&client);              /* 0 */
//! discord_client_deinit(&client);              /* DISCORD_CLIENT_INVALID */
//! discord_client_clear_presence(&client);      /* DISCORD_CLIENT_INVALID */
//! ```
//!
//! - The handle is the caller's storage and must stay at one address until it is closed.
//! - `discord_client_stop` pauses a client and keeps the handle, so `discord_client_start`
//!   resumes without rebuilding it.
//! - `optional_environ` is a NULL-terminated array of `KEY=value` strings, read only during
//!   the call; NULL takes the environment the process was started with. It is what the
//!   endpoint is looked up through and what a registered handler is written against.
//!
//! ---
//!
//! ## Events
//!
//! Events are taken one at a time, on the calling thread, and `timeout_ms` says how long to
//! wait for one:
//!
//! ```c
//! discord_client_next_event(&client, &event, 0);    /* whatever is already there */
//! discord_client_next_event(&client, &event, -1);   /* until one arrives, or the client stops */
//! discord_client_next_event(&client, &event, 250);  /* at most a quarter second */
//! ```
//!
//! `DISCORD_CLIENT_EMPTY` says the wait ended with none ready, which is how a drain loop ends:
//!
//! ```c
//! DiscordEvent event;
//! /* inside a frame loop: take what is ready */
//! while (discord_client_next_event(&client, &event, 0) == DISCORD_CLIENT_OK) {
//!     switch (event.kind) { /* ... */ }
//! }
//! ```
//!
//! A dedicated thread passes a negative timeout and sleeps between events.
//!
//! One flat `ForeignEvent` carries every kind: read `kind`, then the fields it names. Each
//! kind fills those and leaves the rest NULL. A `notice` names the `Subscription` that fired
//! in `subscribed`, and the `PayloadShape` its fields follow in `shape`:
//!
//! ```c
//! if (event.kind == DISCORD_EVENT_NOTICE) switch (event.shape) {
//!     case DISCORD_PAYLOAD_MESSAGE:
//!         printf("%s: %s\n", event.user.username, event.body);
//!         break;
//!     case DISCORD_PAYLOAD_SPEAKING:
//!         mark_speaking(event.channel_id);
//!         break;
//!     default:
//!         break;
//! }
//! ```
//!
//! > An event's strings point into the client and stay valid until the next call on it. Copy
//! > what you keep.
//!
//! `discord_client_subscribe` names one event from the `Subscription` numbering and the object
//! it is watched on: the nine keyed by a guild or a channel take that id as `optional_key`, and
//! the rest take NULL.
//!
//! ```c
//! discord_client_subscribe(&client, DISCORD_SUBSCRIBE_ACTIVITY_JOIN, NULL);
//! discord_client_subscribe(&client, DISCORD_SUBSCRIBE_GUILD_STATUS, "333333333333333333");
//! discord_client_unsubscribe(&client, DISCORD_SUBSCRIBE_ACTIVITY_JOIN, NULL);
//! ```
//!
//! A subscription made before the client connects is carried by the first connection, and a
//! reconnect carries the whole set again.
//!
//! ---
//!
//! ## Commands
//!
//! `discord_client_authorize` puts Discord's consent modal in front of the user and answers
//! the one-time code they approved; `discord_client_authenticate` hands back a token minted
//! from that code and answers the account it belongs to.
//!
//! > The exchange between the two carries an application secret, so it happens on a server the
//! > application owns, away from anything shipped to players.
//!
//! The voice commands take their optional members as pointers, so a zeroed struct changes
//! nothing and a NULL member leaves that setting as Discord has it:
//!
//! ```c
//! DiscordVoiceUpdate update;
//! DiscordVoiceSettings settings;
//! memset(&update, 0, sizeof update);
//!
//! bool mute = true;
//! float volume = 80.0f;
//! update.mute = &mute;
//! update.input_volume = &volume;
//! update.shortcut_count = -1;   /* leave the push-to-talk binding alone */
//!
//! discord_client_set_voice_settings(&client, &update, &settings);
//! for (int i = 0; i < settings.input.device_count; i++)
//!     puts(settings.input.devices[i].name);
//! ```
//!
//! The guild and channel commands spell their text into arrays inside the struct the caller
//! passes, so what comes back is the caller's for as long as it keeps it:
//!
//! ```c
//! DiscordGuildList guilds;
//! discord_client_guilds(&client, &guilds);
//! for (int i = 0; i < guilds.count; i++)
//!     puts(guilds.guilds[i].name);
//!
//! DiscordChannel joined;
//! discord_client_select_voice_channel(&client, "444444444444444444", 0, true, false, &joined);
//! if (joined.found) puts(joined.name);
//! ```
//!
//! A `found` of false is a user who is in no channel, which is also how leaving one answers,
//! and a `count` says how many entries a list filled.
//!
//! ---
//!
//! ## Registration
//!
//! `discord_register` claims the `discord-<application_id>://` scheme, which is how Discord
//! launches a game from an invite; a null command claims it for the running executable, and
//! `discord_register_steam_game` claims it for a game Steam launches. Both stand alone, so a
//! caller can claim the scheme without opening a client. `auto_register` on `init` does the
//! same for the running executable, or for `optional_steam_id` when one is given.
//!
//! ---
//!
//! ## Linking
//!
//! `-Dlinkage` picks how the library is emitted. Windows spells an import library and a static
//! archive both `.lib`, so one build produces one of them:
//!
//! ```sh
//! zig build                    # libdiscord-rpc-c.so / .dylib, discord-rpc-c.dll
//! zig build -Dlinkage=static   # libdiscord-rpc-c.a, discord-rpc-c.lib
//! ```
//!
//! The archive carries the Zig runtime with it, so it is enough to link on its own:
//!
//! ```sh
//! cc yours.c zig-out/lib/libdiscord-rpc-c.a -o yours
//! ```

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Io = std.Io;
const Environ = std.process.Environ;
const discord = @import("discord_rpc");

const Client = discord.Client;
const Presence = discord.Presence;
const User = discord.User;
const register = discord.register;
const rpc = discord.rpc;

pub const InitStatus = enum(c_int) {
    success = 0,
    unexpected = 1,
    out_of_memory = 2,
    application_id_invalid = 3,
    system_resources = 4,
    /// `auto_register` was asked for and the system declined it.
    registration_failed = 5,
    canceled = 6,
    /// `discord_client_start` was handed a handle that is closed or was never opened.
    client_invalid = 7,
};

pub const ClientStatus = enum(c_int) {
    ok = 0,
    /// The handle was never initialized, or has already been closed.
    invalid = 1,
    presence_invalid = 2,
    payload_too_large = 3,
    canceled = 4,
    /// `discord_client_next_event` ended its wait with none ready.
    empty = 5,
    /// Every request slot is held; the caller retries once one frees.
    busy = 6,
    /// The reply went with the connection, or the wait ran out.
    disconnected = 7,
    /// Discord answered the request with a refusal, which the `errored` event names.
    refused = 8,
    /// Discord answered, and what came back was not the shape the command names.
    malformed = 9,
};

/// How `discord_client_respond` answers an ask to join.
pub const Reply = enum(c_int) { no = 0, yes = 1, ignore = 2 };

/// Who a presence lets join the party.
pub const Privacy = enum(c_int) { private = 0, public = 1 };

/// `RichPresence.status_display_type`.
pub const StatusDisplayType = enum(c_int) { name = 0, state = 1, details = 2 };

/// `RichPresence.activity_type`. Discord numbers these and adds to them, so a value this does
/// not name is carried through as it stands.
pub const ActivityType = enum(c_int) {
    playing = 0,
    streaming = 1,
    listening = 2,
    watching = 3,
    custom = 4,
    competing = 5,
    _,
};

/// `ForeignVoiceMode.kind`, and what `ForeignVoiceUpdate.mode` points at.
pub const VoiceMode = enum(c_int) { push_to_talk = 0, voice_activity = 1 };

/// `ForeignCertifiedDevice.kind`.
pub const DeviceKind = enum(c_int) { audio_input = 0, audio_output = 1, video_input = 2 };

/// Every number this ABI publishes for something the client names itself. A tag inserted or
/// reordered on either side renumbers the contract, and is caught here.
fn mirrors(comptime Published: type, comptime Named: type) void {
    const published = std.enums.values(Published);
    const named = std.enums.values(Named);
    assert(published.len == named.len);

    for (published, named) |a, b| {
        assert(@backingInt(a) == @backingInt(b));
        assert(std.mem.eql(u8, @tagName(a), @tagName(b)));
    }
}

comptime {
    mirrors(Reply, Client.Reply);
    mirrors(Privacy, Presence.Privacy);
    mirrors(StatusDisplayType, Presence.StatusDisplayType);
    mirrors(ActivityType, Presence.ActivityType);
    mirrors(VoiceMode, rpc.VoiceSettings.Mode.Kind);
    mirrors(DeviceKind, rpc.CertifiedDevice.Kind);
    mirrors(EventKind, @typeInfo(Client.Event).@"union".tag_type.?);
    mirrors(Subscription, rpc.Event);
    mirrors(PayloadShape, rpc.Payload.Shape);
}

/// The value a published number names, or null for one outside the numbering.
fn spoken(comptime Spoken: type, value: c_int) ?Spoken {
    for (std.enums.values(Spoken)) |candidate| {
        if (value == @backingInt(candidate)) return candidate;
    }
    return null;
}

/// The events `subscribe` asks Discord for, and the one a `notice` carries back. The nine
/// keyed by a guild or a channel take that id as the key; the rest take null.
pub const Subscription = enum(c_int) {
    current_user_update = 0,
    relationship_update = 1,
    guild_status = 2,
    guild_create = 3,
    channel_create = 4,
    voice_channel_select = 5,
    voice_state_create = 6,
    voice_state_update = 7,
    voice_state_delete = 8,
    voice_settings_update = 9,
    voice_connection_status = 10,
    speaking_start = 11,
    speaking_stop = 12,
    message_create = 13,
    message_update = 14,
    message_delete = 15,
    notification_create = 16,
    activity_join = 17,
    activity_spectate = 18,
    activity_join_request = 19,
    activity_invite = 20,
    entitlement_create = 21,
    entitlement_delete = 22,
};

/// Discord names fewer than this, so a caller asking for more has asked for something else.
const max_scopes = 24;

pub const ForeignButton = extern struct {
    label: ?[*:0]const u8,
    url: ?[*:0]const u8,
};

/// What `discord_client_set_presence` shows. A zeroed struct clears every field, and a null
/// string leaves that field out.
pub const RichPresence = extern struct {
    state: ?[*:0]const u8,
    details: ?[*:0]const u8,
    /// Opened when the player taps the line it belongs to. A web scheme and printable ASCII.
    state_url: ?[*:0]const u8,
    details_url: ?[*:0]const u8,
    /// Which field feeds the status message: 0 the application name, 1 the state,
    /// 2 the details. The values `StatusDisplayType` names.
    status_display_type: c_int,
    start_timestamp: i64,
    end_timestamp: i64,
    large_image_key: ?[*:0]const u8,
    large_image_text: ?[*:0]const u8,
    large_image_url: ?[*:0]const u8,
    small_image_key: ?[*:0]const u8,
    small_image_text: ?[*:0]const u8,
    small_image_url: ?[*:0]const u8,
    party_id: ?[*:0]const u8,
    party_size: c_int,
    party_max: c_int,
    party_privacy: c_int,
    match_secret: ?[*:0]const u8,
    join_secret: ?[*:0]const u8,
    spectate_secret: ?[*:0]const u8,
    instance: i8,
    /// How Discord phrases the activity, as the values `ActivityType` names.
    activity_type: c_int,
    buttons: ?[*]const ForeignButton,
    button_count: c_int,
};

pub const ForeignDevice = extern struct {
    id: ?[*:0]const u8,
    name: ?[*:0]const u8,
};

/// `kind` is Discord's own numbering: 0 keyboard key, 1 mouse button,
/// 2 keyboard modifier, 3 gamepad button.
pub const ForeignShortcut = extern struct {
    kind: c_int,
    code: c_int,
    name: ?[*:0]const u8,
};

pub const ForeignVoiceChannel = extern struct {
    device_id: ?[*:0]const u8,
    volume: f32,
    devices: ?[*]const ForeignDevice,
    device_count: c_int,
};

pub const ForeignVoiceMode = extern struct {
    /// 0 push-to-talk, 1 voice activity.
    kind: c_int,
    auto_threshold: bool,
    threshold: f32,
    delay: f32,
    shortcut: ?[*]const ForeignShortcut,
    shortcut_count: c_int,
};

/// The configuration Discord reports. Its strings and arrays point into the client and stay
/// valid until the next call on it, so copy what you keep.
pub const ForeignVoiceSettings = extern struct {
    input: ForeignVoiceChannel,
    output: ForeignVoiceChannel,
    mode: ForeignVoiceMode,
    automatic_gain_control: bool,
    echo_cancellation: bool,
    noise_suppression: bool,
    qos: bool,
    silence_warning: bool,
    deaf: bool,
    mute: bool,
};

/// What to change. A null member leaves that setting as Discord has it, so a zeroed struct
/// changes nothing. `shortcut_count` below zero leaves the binding alone.
pub const ForeignVoiceUpdate = extern struct {
    input_device_id: ?[*:0]const u8,
    input_volume: ?*const f32,
    output_device_id: ?[*:0]const u8,
    output_volume: ?*const f32,
    mode: ?*const c_int,
    mode_auto_threshold: ?*const bool,
    mode_threshold: ?*const f32,
    mode_delay: ?*const f32,
    shortcut: ?[*]const ForeignShortcut,
    shortcut_count: c_int,
    automatic_gain_control: ?*const bool,
    echo_cancellation: ?*const bool,
    noise_suppression: ?*const bool,
    qos: ?*const bool,
    silence_warning: ?*const bool,
    deaf: ?*const bool,
    mute: ?*const bool,
};

/// One user's mix. A null member is one this caller is not setting; on the way back a
/// `has_` flag says whether Discord named it.
pub const ForeignUserVoice = extern struct {
    pan_left: ?*const f32,
    pan_right: ?*const f32,
    volume: ?*const c_int,
    mute: ?*const bool,
};

pub const ForeignUserVoiceApplied = extern struct {
    has_pan: bool,
    pan_left: f32,
    pan_right: f32,
    has_volume: bool,
    volume: c_int,
    has_mute: bool,
    mute: bool,
};

/// The list and channel commands write into storage the caller owns, spelling their text in
/// place, so what comes back outlives every later call and is the caller's to size.
pub const ForeignGuild = extern struct {
    id: [rpc.snowflake_bytes + 1]u8,
    name: [rpc.Guild.name_bytes + 1]u8,
    icon_url: [rpc.Guild.url_bytes + 1]u8,
};

pub const ForeignGuildList = extern struct {
    guilds: [rpc.GuildList.capacity]ForeignGuild,
    count: c_int,
};

pub const ForeignVoiceState = extern struct {
    user: ForeignUserText,
    nick: [rpc.VoiceState.nick_bytes + 1]u8,
    /// As the guild has them.
    mute: bool,
    deaf: bool,
    /// As they have themselves.
    self_mute: bool,
    self_deaf: bool,
    suppress: bool,
    /// The local client's own mix for this person.
    locally_muted: bool,
    volume: c_int,
    pan_left: f32,
    pan_right: f32,
};

/// The account fields spelled in place, since a voice state outlives the call that filled it.
pub const ForeignUserText = extern struct {
    id: [User.capacityOf("id") + 1]u8,
    username: [User.capacityOf("username") + 1]u8,
    discriminator: [User.capacityOf("discriminator") + 1]u8,
    avatar: [User.capacityOf("avatar") + 1]u8,
};

/// `found` says whether Discord named a channel; a caller that left one is answered with none.
/// `kind` is Discord's own numbering: guild text 0, dm 1, guild voice 2, group dm 3.
pub const ForeignChannel = extern struct {
    found: bool,
    id: [rpc.snowflake_bytes + 1]u8,
    guild_id: [rpc.snowflake_bytes + 1]u8,
    name: [rpc.Channel.name_bytes + 1]u8,
    kind: c_int,
    topic: [rpc.Channel.topic_bytes + 1]u8,
    bitrate: c_int,
    user_limit: c_int,
    position: c_int,
    voice_states: [rpc.Channel.voice_state_capacity]ForeignVoiceState,
    voice_state_count: c_int,
};

pub const ForeignChannelSummary = extern struct {
    id: [rpc.snowflake_bytes + 1]u8,
    name: [rpc.Channel.name_bytes + 1]u8,
    kind: c_int,
};

pub const ForeignChannelList = extern struct {
    channels: [rpc.ChannelList.capacity]ForeignChannelSummary,
    count: c_int,
};

/// `kind` is 0 audio input, 1 audio output, 2 video input. A null `echo_cancellation` and the
/// three beside it leave that capability unstated.
pub const ForeignCertifiedDevice = extern struct {
    kind: c_int,
    id: ?[*:0]const u8,
    vendor_name: ?[*:0]const u8,
    vendor_url: ?[*:0]const u8,
    model_name: ?[*:0]const u8,
    model_url: ?[*:0]const u8,
    related: ?[*]const ?[*:0]const u8,
    related_count: c_int,
    echo_cancellation: ?*const bool,
    noise_suppression: ?*const bool,
    automatic_gain_control: ?*const bool,
    hardware_mute: ?*const bool,
};

pub const ForeignUser = extern struct {
    user_id: ?[*:0]const u8,
    username: ?[*:0]const u8,
    discriminator: ?[*:0]const u8,
    avatar: ?[*:0]const u8,
};

/// Which of a `notice` event's fields carry what it arrived with. `Subscription` decides this,
/// so an event always brings the same shape.
pub const PayloadShape = enum(c_int) {
    none = 0,
    user = 1,
    relationship = 2,
    guild = 3,
    channel = 4,
    voice_channel = 5,
    voice_state = 6,
    connection = 7,
    speaking = 8,
    message = 9,
    notification = 10,
    invite = 11,
    entitlement = 12,
};

/// Which fields of a `ForeignEvent` the kind fills.
pub const EventKind = enum(c_int) {
    ready = 0,
    disconnected = 1,
    errored = 2,
    join_game = 3,
    spectate_game = 4,
    join_request = 5,
    notice = 6,
};

/// One flat shape for every kind, so a caller reads `kind` and then the fields it names.
/// Each kind fills those fields and leaves the rest null.
///
/// Its strings point into the client and stay valid until the next call on that client.
pub const ForeignEvent = extern struct {
    kind: c_int,
    /// `disconnected` and `errored`. Discord's own numbering when it sent the report,
    /// `Connection.ErrorCode` when this library detected the failure.
    code: c_int,
    /// `notice`. The `Subscription` that fired.
    subscribed: c_int,
    /// `notice`. The `PayloadShape` that names which of the fields below it filled.
    shape: c_int,
    message: ?[*:0]const u8,
    secret: ?[*:0]const u8,
    /// The account the event is about: whose message, whose notification, who is speaking,
    /// who invited, whose relationship changed.
    user: ForeignUser,
    /// `notice`. The ids the payload named.
    channel_id: ?[*:0]const u8,
    guild_id: ?[*:0]const u8,
    /// `notice`. A guild or channel name, or a voice connection's state.
    name: ?[*:0]const u8,
    /// `notice`. A notification's title.
    title: ?[*:0]const u8,
    /// `notice`. A message's content, or a notification's body.
    body: ?[*:0]const u8,
};

/// The caller owns this storage and must keep it at one address for the client's lifetime.
/// Its contents belong to the implementation.
pub const Handle = extern struct {
    opaque_fields: [2]u64,

    /// Paired with the address, so only storage this wrote resolves.
    const magic: u64 = 0x8f3a_1c77_b204_e659;

    fn open(handle: *Handle, state: *State) void {
        const address: u64 = @intFromPtr(state);
        handle.* = .{ .opaque_fields = .{ address, address ^ magic } };
        assert(handle.resolve() == state);
    }

    fn close(handle: *Handle) void {
        handle.* = .{ .opaque_fields = .{ 0, 0 } };
        assert(handle.resolve() == null);
    }

    fn resolve(handle: *const Handle) ?*State {
        const address = handle.opaque_fields[0];
        if (address == 0) return null;
        if (handle.opaque_fields[1] != address ^ magic) return null;
        return @ptrFromInt(@as(usize, @intCast(address)));
    }
};

/// This module always links libc, which is the case `start.zig` picks `c_allocator` for.
const allocator = std.heap.c_allocator;

/// `Io.Threaded.init` installs a process-wide `SIGIO` handler and `deinit` restores whatever it
/// replaced, so a second instance torn down out of order restores the default action while the
/// first still runs, and its next cancellation kills the process. Every client shares this one.
var runtime: Runtime = .{};

const Runtime = struct {
    /// `Io.Mutex` would need the `Io` this guards, and opening a client is rare enough that
    /// a waiter can spin.
    mutex: std.atomic.Mutex = .unlocked,
    threaded: Io.Threaded = undefined,
    clients: u32 = 0,

    fn acquire(self: *Runtime) Io {
        self.lock();
        defer self.mutex.unlock();

        // `Io.Threaded` resolves a spawned tool's PATH through its own environment, which is
        // how `register` finds `xdg-mime`.
        if (self.clients == 0) self.threaded = .init(allocator, .{
            .environ = .{ .block = environBlock() },
        });
        self.clients += 1;
        assert(self.clients > 0);
        return self.threaded.io();
    }

    fn release(self: *Runtime) void {
        self.lock();
        defer self.mutex.unlock();

        assert(self.clients > 0);
        self.clients -= 1;
        if (self.clients == 0) self.threaded.deinit();
    }

    fn lock(self: *Runtime) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
};

/// A client costs `Client.max_footprint_bytes` and must not move, so this lives on the heap
/// and the handle carries its address.
const State = struct {
    io: Io,
    environ: Environ.Map,
    /// What the last event handed out points into, so one event lives until the next.
    storage: EventStorage,
    /// The same for the last voice configuration reported.
    voice: VoiceStorage,
    client: Client,

    fn destroy(self: *State) void {
        self.client.deinit(self.io);
        self.environ.deinit();
        allocator.destroy(self);
        runtime.release();
    }
};

/// This Zig hands the environment to `main`, and a library has no `main`: Windows reads its own
/// block through `ntdll`, and libc owns the one everywhere else.
fn environBlock() Environ.Block {
    if (builtin.os.tag == .windows) return .global;
    return .{ .slice = @ptrCast(std.mem.span(std.c.environ)) };
}

fn captureEnviron(
    gpa: std.mem.Allocator,
    given: ?[*:null]const ?[*:0]const u8,
) Environ.CreateMapError!Environ.Map {
    const block: Environ.Block = if (given) |entries| block: {
        const entered: Environ.PosixBlock = .{ .slice = std.mem.span(entries) };

        // A Windows block is UTF-16, so these go into the map directly.
        if (builtin.os.tag == .windows) {
            var map: Environ.Map = .init(gpa);
            errdefer map.deinit();
            try map.putPosixBlock(entered.view());
            return map;
        }
        break :block entered;
    } else environBlock();

    const source: Environ = .{ .block = block };
    return source.createMap(gpa);
}

/// What a claim on the `discord-<application_id>://` scheme launches. A null
/// command names the running executable.
const Scheme = union(enum) {
    command: ?[]const u8,
    steam_id: []const u8,
};

fn claim(io: Io, environ: *Environ.Map, id: []const u8, scheme: Scheme) register.Error!void {
    assert(id.len > 0);
    return switch (scheme) {
        .command => |command| register.handler(io, environ, id, command),
        .steam_id => |steam_id| register.steamGame(io, environ, id, steam_id),
    };
}

/// Claims the scheme on its own, for a caller that registers without opening a client. Runs
/// the whole claim before returning, so the `Io` it needs lives only for the call.
fn claimAlone(
    application_id: ?[*:0]const u8,
    optional_environ: ?[*:null]const ?[*:0]const u8,
    scheme: Scheme,
) InitStatus {
    const id = std.mem.span(application_id orelse return .application_id_invalid);
    if (id.len == 0) return .application_id_invalid;

    var environ = captureEnviron(allocator, optional_environ) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.Unexpected => .unexpected,
    };
    defer environ.deinit();

    const io = runtime.acquire();
    defer runtime.release();

    claim(io, &environ, id, scheme) catch return .registration_failed;
    return .success;
}

/// Claims the `discord-<application_id>://` scheme, which is how Discord launches a game from
/// an invite. A null command claims it for the running executable.
pub export fn discord_register(
    application_id: ?[*:0]const u8,
    optional_environ: ?[*:null]const ?[*:0]const u8,
    optional_command: ?[*:0]const u8,
) InitStatus {
    return claimAlone(application_id, optional_environ, .{
        .command = optional(optional_command),
    });
}

/// Claims it for a game Steam launches.
pub export fn discord_register_steam_game(
    application_id: ?[*:0]const u8,
    optional_environ: ?[*:null]const ?[*:0]const u8,
    steam_id: ?[*:0]const u8,
) InitStatus {
    const steam = std.mem.span(steam_id orelse return .registration_failed);
    if (steam.len == 0) return .registration_failed;
    return claimAlone(application_id, optional_environ, .{ .steam_id = steam });
}

/// Opens a client into `client_out`, which must stay at one address until it is closed.
/// Returns `success`, or a status naming what stopped it and leaves `client_out` unopened.
///
/// `optional_environ` is a NULL-terminated array of `KEY=value` strings, read only during this
/// call. Passing null takes the environment the process was started with, which is where the
/// endpoint and the handler registration are looked up.
pub export fn discord_client_init(
    client_out: *Handle,
    application_id: ?[*:0]const u8,
    optional_environ: ?[*:null]const ?[*:0]const u8,
    auto_register: bool,
    optional_steam_id: ?[*:0]const u8,
) InitStatus {
    const id = std.mem.span(application_id orelse return .application_id_invalid);
    if (id.len == 0) return .application_id_invalid;

    const gpa = allocator;
    const self = gpa.create(State) catch return .out_of_memory;
    const environ = captureEnviron(gpa, optional_environ) catch |err| {
        gpa.destroy(self);
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.Unexpected => .unexpected,
        };
    };
    self.* = .{
        .io = runtime.acquire(),
        .environ = environ,
        .storage = undefined,
        .voice = undefined,
        .client = undefined,
    };
    self.client.init(.{ .application_id = id });

    if (auto_register) {
        const scheme: Scheme = if (optional_steam_id) |steam_id|
            .{ .steam_id = std.mem.span(steam_id) }
        else
            .{ .command = null };

        claim(self.io, &self.environ, id, scheme) catch {
            self.destroy();
            return .registration_failed;
        };
    }

    const started = startStatus(self);
    if (started != .success) {
        self.destroy();
        return started;
    }

    client_out.open(self);
    return .success;
}

/// The reader and the writer, under the status a caller sees for them.
fn startStatus(self: *State) InitStatus {
    self.client.start(self.io, &self.environ) catch |err| return switch (err) {
        error.InvalidApplicationId => .application_id_invalid,
        error.ConcurrencyUnavailable => .system_resources,
        error.Canceled => .canceled,
        error.AlreadyStarted => .unexpected,
    };
    return .success;
}

/// Runs a client that was stopped. Starting one already running answers `unexpected`.
pub export fn discord_client_start(client: *Handle) InitStatus {
    const self = client.resolve() orelse return .client_invalid;
    return startStatus(self);
}

/// Stops the reader and the writer, keeping the handle open for `discord_client_start`.
pub export fn discord_client_stop(client: *Handle) ClientStatus {
    const self = client.resolve() orelse return .invalid;
    self.client.stop(self.io);
    return .ok;
}

/// Answers whether the reader and the writer are running.
pub export fn discord_client_is_running(client: *Handle, running_out: *bool) ClientStatus {
    const self = client.resolve() orelse return .invalid;
    running_out.* = self.client.isRunning();
    return .ok;
}

/// Asks Discord for one more event. A connection carries the change at once, and a reconnect
/// carries the whole set again.
///
/// `optional_key` is the guild or channel id a keyed event is watched on, and is null for the
/// events Discord watches globally. Either one supplied where the other belongs answers `invalid`.
pub export fn discord_client_subscribe(
    client: *Handle,
    subscribed: c_int,
    optional_key: ?[*:0]const u8,
) ClientStatus {
    const self = client.resolve() orelse return .invalid;
    const raised = spoken(rpc.Event, subscribed) orelse return .invalid;

    self.client.subscribe(self.io, raised, key(optional_key)) catch |err| {
        return subscribeStatus(err);
    };
    return .ok;
}

/// Gives one back. An event that was never asked for answers `ok`.
pub export fn discord_client_unsubscribe(
    client: *Handle,
    subscribed: c_int,
    optional_key: ?[*:0]const u8,
) ClientStatus {
    const self = client.resolve() orelse return .invalid;
    const raised = spoken(rpc.Event, subscribed) orelse return .invalid;

    self.client.unsubscribe(self.io, raised, key(optional_key)) catch |err| {
        return subscribeStatus(err);
    };
    return .ok;
}

/// Reads back whether the client is asking for this event; the request may still be
/// outstanding on the wire.
pub export fn discord_client_is_subscribed(
    client: *Handle,
    subscribed: c_int,
    optional_key: ?[*:0]const u8,
    subscribed_out: *bool,
) ClientStatus {
    const self = client.resolve() orelse return .invalid;
    const raised = spoken(rpc.Event, subscribed) orelse return .invalid;

    subscribed_out.* = self.client.isSubscribed(self.io, raised, key(optional_key));
    return .ok;
}

fn key(optional_key: ?[*:0]const u8) []const u8 {
    return std.mem.span(optional_key orelse return "");
}

fn subscribeStatus(err: Client.SubscribeError) ClientStatus {
    return switch (err) {
        error.InvalidSubscription => .invalid,
        error.SubscriptionsFull => .busy,
        error.PayloadTooLarge => .payload_too_large,
        error.Canceled => .canceled,
    };
}

/// Closes the client and releases everything it holds, leaving the handle closed.
pub export fn discord_client_deinit(client: *Handle) ClientStatus {
    const self = client.resolve() orelse return .invalid;
    client.close();
    self.destroy();
    return .ok;
}

/// Takes the next event into `event_out`, on the calling thread.
///
/// `timeout_ms` is how long to wait for one: zero takes only what is already there, negative
/// sleeps until one arrives or the client stops, and a positive value bounds the sleep.
/// Returns `empty` when the wait ends with none ready, which is how a drain loop ends.
pub export fn discord_client_next_event(
    client: *Handle,
    event_out: *ForeignEvent,
    timeout_ms: c_int,
) ClientStatus {
    const self = client.resolve() orelse return .invalid;

    const taken = if (timeout_ms == 0)
        self.client.nextEvent(self.io) catch |err| return status(err)
    else taken: {
        const timeout: Io.Timeout = if (timeout_ms < 0)
            .none
        else
            discord.milliseconds(@intCast(timeout_ms));
        break :taken self.client.waitEvent(self.io, timeout) catch |err| return status(err);
    };

    self.storage.fill(event_out, &(taken orelse return .empty));

    // The fill holds the same range, so a kind the caller could not read shows up here.
    assert(event_out.kind >= @backingInt(EventKind.ready));
    assert(event_out.kind <= @backingInt(EventKind.notice));
    return .ok;
}

/// A null `presence` clears it.
pub export fn discord_client_set_presence(
    client: *Handle,
    presence: ?*const RichPresence,
) ClientStatus {
    const self = client.resolve() orelse return .invalid;
    const given = presence orelse return discord_client_clear_presence(client);

    if (given.button_count < 0) return .presence_invalid;
    if (given.button_count > Presence.max_buttons) return .presence_invalid;

    var buttons: [Presence.max_buttons]Presence.Button = undefined;
    const button_count: usize = @intCast(given.button_count);
    assert(button_count <= buttons.len);

    if (button_count > 0) {
        const entries = given.buttons orelse return .presence_invalid;
        for (buttons[0..button_count], entries[0..button_count]) |*slot, entry| {
            slot.* = .{
                .label = optional(entry.label) orelse "",
                .url = optional(entry.url) orelse "",
            };
        }
    }

    const activity: Presence = .{
        .state = optional(given.state),
        .details = optional(given.details),
        .state_url = optional(given.state_url),
        .details_url = optional(given.details_url),
        .status_display_type = spoken(Presence.StatusDisplayType, given.status_display_type) orelse
            .name,
        .start_timestamp = if (given.start_timestamp == 0) null else given.start_timestamp,
        .end_timestamp = if (given.end_timestamp == 0) null else given.end_timestamp,
        .large_image_key = optional(given.large_image_key),
        .large_image_text = optional(given.large_image_text),
        .large_image_url = optional(given.large_image_url),
        .small_image_key = optional(given.small_image_key),
        .small_image_text = optional(given.small_image_text),
        .small_image_url = optional(given.small_image_url),
        .party_id = optional(given.party_id),
        .party_size = count(given.party_size),
        .party_max = count(given.party_max),
        .party_privacy = privacy(given.party_privacy),
        .match_secret = optional(given.match_secret),
        .join_secret = optional(given.join_secret),
        .spectate_secret = optional(given.spectate_secret),
        .instance = given.instance != 0,
        .activity_type = activityType(given.activity_type),
        .buttons = buttons[0..button_count],
    };
    self.client.updatePresence(self.io, &activity) catch |err| return status(err);
    return .ok;
}

pub export fn discord_client_clear_presence(client: *Handle) ClientStatus {
    const self = client.resolve() orelse return .invalid;
    self.client.clearPresence(self.io) catch |err| return status(err);
    return .ok;
}

fn requestStatus(err: Client.AcceptError) ClientStatus {
    return switch (err) {
        error.RequestsBusy => .busy,
        error.Disconnected => .disconnected,
        error.Refused => .refused,
        error.PayloadTooLarge => .payload_too_large,
        error.BadPayload => .malformed,
        error.Canceled => .canceled,
    };
}

/// Every request the client turns back before sending it, so each named argument answers the
/// same way whichever command it belonged to.
const ArgumentError = Client.AcceptError || error{
    InvalidToken,
    InvalidScopes,
    InvalidVoiceSettings,
    InvalidDevice,
    InvalidUser,
    InvalidId,
};

fn argumentStatus(err: ArgumentError) ClientStatus {
    return switch (err) {
        error.InvalidToken,
        error.InvalidScopes,
        error.InvalidVoiceSettings,
        error.InvalidDevice,
        error.InvalidUser,
        error.InvalidId,
        => .invalid,
        else => |rest| requestStatus(rest),
    };
}

/// Puts Discord's consent modal in front of the user and writes the one-time code they
/// approved into `code_out`, which must hold `capacity` bytes.
///
/// Trading that code for a token carries an application secret, so it happens on a server the
/// application owns. `scopes` is a NULL-terminated array of scope names.
pub export fn discord_client_authorize(
    client: *Handle,
    scopes: ?[*:null]const ?[*:0]const u8,
    code_out: ?[*]u8,
    capacity: usize,
) ClientStatus {
    const self = client.resolve() orelse return .invalid;
    const out = code_out orelse return .invalid;
    if (capacity == 0) return .invalid;

    var wanted: [max_scopes][]const u8 = undefined;
    const count_wanted = gatherScopes(&wanted, scopes orelse return .invalid) orelse
        return .invalid;

    const code = self.client.authorize(self.io, wanted[0..count_wanted]) catch |err| {
        return argumentStatus(err);
    };

    const spelled = code.slice();
    if (spelled.len + 1 > capacity) return .payload_too_large;

    @memcpy(out[0..spelled.len], spelled);
    out[spelled.len] = 0;
    return .ok;
}

/// Hands Discord a token the caller already exchanged for, and fills `user_out` with the
/// account it belongs to.
pub export fn discord_client_authenticate(
    client: *Handle,
    access_token: ?[*:0]const u8,
    user_out: *ForeignUser,
) ClientStatus {
    const self = client.resolve() orelse return .invalid;
    const token = std.mem.span(access_token orelse return .invalid);

    const user = self.client.authenticate(self.io, token) catch |err| return argumentStatus(err);

    self.storage.fillUser(user_out, user);
    return .ok;
}

/// More than Discord names is refused, so a scope the caller asked for is never left off.
fn gatherScopes(out: *[max_scopes][]const u8, given: [*:null]const ?[*:0]const u8) ?usize {
    var found: usize = 0;
    while (given[found]) |scope| : (found += 1) {
        if (found == out.len) return null;
        out[found] = std.mem.span(scope);
        if (out[found].len == 0) return null;
    }

    assert(found <= out.len);
    if (found == 0) return null;
    return found;
}

/// Answers a join request. An unrecognized `reply` refuses it.
pub export fn discord_client_respond(
    client: *Handle,
    user_id: ?[*:0]const u8,
    reply: c_int,
) ClientStatus {
    const self = client.resolve() orelse return .invalid;
    const id = std.mem.span(user_id orelse return .invalid);

    const answer: Client.Reply = switch (reply) {
        @backingInt(Reply.yes) => .yes,
        @backingInt(Reply.ignore) => .ignore,
        else => .no,
    };
    self.client.respond(self.io, id, answer) catch |err| return argumentStatus(err);
    return .ok;
}

/// Reads back the local voice configuration into `settings_out`.
pub export fn discord_client_voice_settings(
    client: *Handle,
    settings_out: *ForeignVoiceSettings,
) ClientStatus {
    const self = client.resolve() orelse return .invalid;

    const settings = self.client.voiceSettings(self.io) catch |err| return requestStatus(err);
    self.voice.fill(settings_out, &settings);
    return .ok;
}

/// Changes what `update` names and reads back the whole configuration Discord settled on,
/// which is where a level it clamped shows up.
pub export fn discord_client_set_voice_settings(
    client: *Handle,
    update: *const ForeignVoiceUpdate,
    settings_out: *ForeignVoiceSettings,
) ClientStatus {
    const self = client.resolve() orelse return .invalid;

    var keys: [rpc.VoiceSettings.shortcut_capacity]rpc.VoiceSettings.Shortcut = undefined;
    const shortcut = gatherShortcut(&keys, update) catch return .invalid;

    const wanted: rpc.VoiceSettings.Update = .{
        .input_device_id = optional(update.input_device_id),
        .input_volume = pointed(f32, update.input_volume),
        .output_device_id = optional(update.output_device_id),
        .output_volume = pointed(f32, update.output_volume),
        .mode = voiceMode(update.mode),
        .mode_auto_threshold = pointed(bool, update.mode_auto_threshold),
        .mode_threshold = pointed(f32, update.mode_threshold),
        .mode_delay = pointed(f32, update.mode_delay),
        .shortcut = shortcut,
        .automatic_gain_control = pointed(bool, update.automatic_gain_control),
        .echo_cancellation = pointed(bool, update.echo_cancellation),
        .noise_suppression = pointed(bool, update.noise_suppression),
        .qos = pointed(bool, update.qos),
        .silence_warning = pointed(bool, update.silence_warning),
        .deaf = pointed(bool, update.deaf),
        .mute = pointed(bool, update.mute),
    };

    const settings = self.client.setVoiceSettings(self.io, &wanted) catch |err| {
        return argumentStatus(err);
    };
    self.voice.fill(settings_out, &settings);
    return .ok;
}

/// Sets one user's mix in the local client and reads back what Discord applied.
pub export fn discord_client_set_user_voice_settings(
    client: *Handle,
    user_id: ?[*:0]const u8,
    settings: *const ForeignUserVoice,
    applied_out: *ForeignUserVoiceApplied,
) ClientStatus {
    const self = client.resolve() orelse return .invalid;
    const id = std.mem.span(user_id orelse return .invalid);

    const level = pointed(c_int, settings.volume);
    if (level) |given| {
        if (given < 0) return .invalid;
    }

    const wanted: rpc.UserVoiceSettings = .{
        .pan_left = pointed(f32, settings.pan_left),
        .pan_right = pointed(f32, settings.pan_right),
        .volume = if (level) |given| @intCast(given) else null,
        .mute = pointed(bool, settings.mute),
    };

    const mix = self.client.setUserVoiceSettings(self.io, id, &wanted) catch |err| {
        return argumentStatus(err);
    };
    applied_out.* = .{
        .has_pan = mix.pan_left != null,
        .pan_left = mix.pan_left orelse 0,
        .pan_right = mix.pan_right orelse 0,
        .has_volume = mix.volume != null,
        .volume = if (mix.volume) |given| @intCast(given) else 0,
        .has_mute = mix.mute != null,
        .mute = mix.mute orelse false,
    };
    return .ok;
}

/// Reads the guilds the user is in into `list_out`.
pub export fn discord_client_guilds(client: *Handle, list_out: *ForeignGuildList) ClientStatus {
    const self = client.resolve() orelse return .invalid;

    var listed: rpc.GuildList = .empty;
    self.client.guilds(self.io, &listed) catch |err| return argumentStatus(err);

    assert(listed.count <= rpc.GuildList.capacity);
    for (listed.guilds[0..listed.count], list_out.guilds[0..listed.count]) |*held, *out| {
        fillGuild(out, held);
    }
    list_out.count = @intCast(listed.count);
    return .ok;
}

/// Reads one guild into `guild_out`. `timeout_seconds` bounds how long Discord takes to
/// gather it, and zero leaves that to Discord.
pub export fn discord_client_guild(
    client: *Handle,
    guild_id: ?[*:0]const u8,
    timeout_seconds: c_int,
    guild_out: *ForeignGuild,
) ClientStatus {
    const self = client.resolve() orelse return .invalid;
    const id = std.mem.span(guild_id orelse return .invalid);

    var held: rpc.Guild = .empty;
    self.client.guild(self.io, id, timeout_seconds, &held) catch |err| {
        return argumentStatus(err);
    };

    fillGuild(guild_out, &held);
    return .ok;
}

/// Reads what names each channel of one guild into `list_out`.
pub export fn discord_client_channels(
    client: *Handle,
    guild_id: ?[*:0]const u8,
    list_out: *ForeignChannelList,
) ClientStatus {
    const self = client.resolve() orelse return .invalid;
    const id = std.mem.span(guild_id orelse return .invalid);

    var listed: rpc.ChannelList = .empty;
    self.client.channels(self.io, id, &listed) catch |err| return argumentStatus(err);

    assert(listed.count <= rpc.ChannelList.capacity);
    for (listed.channels[0..listed.count], list_out.channels[0..listed.count]) |*held, *out| {
        terminate(rpc.snowflake_bytes, &out.id, held.id.slice());
        terminate(rpc.Channel.name_bytes, &out.name, held.name.slice());
        out.kind = @backingInt(held.kind);
    }
    list_out.count = @intCast(listed.count);
    return .ok;
}

/// Reads one whole channel into `channel_out`, with whoever is in it when it carries voice.
pub export fn discord_client_channel(
    client: *Handle,
    channel_id: ?[*:0]const u8,
    channel_out: *ForeignChannel,
) ClientStatus {
    const self = client.resolve() orelse return .invalid;
    const id = std.mem.span(channel_id orelse return .invalid);

    var held: rpc.Channel = .empty;
    self.client.channel(self.io, id, &held) catch |err| return argumentStatus(err);

    fillChannel(channel_out, &held);
    return .ok;
}

/// Reads the voice channel the user is in. `found` says whether they are in one.
pub export fn discord_client_selected_voice_channel(
    client: *Handle,
    channel_out: *ForeignChannel,
) ClientStatus {
    const self = client.resolve() orelse return .invalid;

    var held: rpc.Channel = .empty;
    self.client.selectedVoiceChannel(self.io, &held) catch |err| return argumentStatus(err);

    fillChannel(channel_out, &held);
    return .ok;
}

/// Puts the user in a voice channel, or takes them out of the one they are in when
/// `optional_channel_id` is null. `found` says which of the two happened.
pub export fn discord_client_select_voice_channel(
    client: *Handle,
    optional_channel_id: ?[*:0]const u8,
    timeout_seconds: c_int,
    force: bool,
    navigate: bool,
    channel_out: *ForeignChannel,
) ClientStatus {
    const self = client.resolve() orelse return .invalid;
    const id: ?[]const u8 = if (optional_channel_id) |given| std.mem.span(given) else null;

    var held: rpc.Channel = .empty;
    self.client.selectVoiceChannel(self.io, id, .{
        .timeout_seconds = timeout_seconds,
        .force = force,
        .navigate = navigate,
    }, &held) catch |err| return argumentStatus(err);

    fillChannel(channel_out, &held);
    return .ok;
}

/// Brings a text channel up in the Discord window, or leaves the one showing when
/// `optional_channel_id` is null. `found` says which of the two happened.
pub export fn discord_client_select_text_channel(
    client: *Handle,
    optional_channel_id: ?[*:0]const u8,
    timeout_seconds: c_int,
    channel_out: *ForeignChannel,
) ClientStatus {
    const self = client.resolve() orelse return .invalid;
    const id: ?[]const u8 = if (optional_channel_id) |given| std.mem.span(given) else null;

    var held: rpc.Channel = .empty;
    self.client.selectTextChannel(self.io, id, timeout_seconds, &held) catch |err| {
        return argumentStatus(err);
    };

    fillChannel(channel_out, &held);
    return .ok;
}

fn fillGuild(out: *ForeignGuild, held: *const rpc.Guild) void {
    terminate(rpc.snowflake_bytes, &out.id, held.id.slice());
    terminate(rpc.Guild.name_bytes, &out.name, held.name.slice());
    terminate(rpc.Guild.url_bytes, &out.icon_url, held.icon_url.slice());
}

fn fillChannel(out: *ForeignChannel, held: *const rpc.Channel) void {
    out.found = held.found;
    terminate(rpc.snowflake_bytes, &out.id, held.id.slice());
    terminate(rpc.snowflake_bytes, &out.guild_id, held.guild_id.slice());
    terminate(rpc.Channel.name_bytes, &out.name, held.name.slice());
    out.kind = @backingInt(held.kind);
    terminate(rpc.Channel.topic_bytes, &out.topic, held.topic.slice());
    out.bitrate = held.bitrate;
    out.user_limit = held.user_limit;
    out.position = held.position;

    assert(held.voice_state_count <= rpc.Channel.voice_state_capacity);
    const counted = held.voice_state_count;
    for (held.voice_states[0..counted], out.voice_states[0..counted]) |*state, *slot| {
        terminate(User.capacityOf("id"), &slot.user.id, state.user.id.slice());
        terminate(User.capacityOf("username"), &slot.user.username, state.user.username.slice());
        terminate(
            User.capacityOf("discriminator"),
            &slot.user.discriminator,
            state.user.discriminator.slice(),
        );
        terminate(User.capacityOf("avatar"), &slot.user.avatar, state.user.avatar.slice());
        terminate(rpc.VoiceState.nick_bytes, &slot.nick, state.nick.slice());

        slot.mute = state.mute;
        slot.deaf = state.deaf;
        slot.self_mute = state.self_mute;
        slot.self_deaf = state.self_deaf;
        slot.suppress = state.suppress;
        slot.locally_muted = state.locally_muted;
        slot.volume = @intCast(state.volume);
        slot.pan_left = state.pan_left;
        slot.pan_right = state.pan_right;
    }
    out.voice_state_count = @intCast(counted);
}

/// Copies into a caller-owned field, truncating what the field cannot hold and leaving the
/// sentinel C reads it back by.
fn terminate(comptime capacity: u32, out: *[capacity + 1]u8, held: []const u8) void {
    const length = @min(held.len, capacity);
    @memcpy(out[0..length], held[0..length]);
    out[length] = 0;

    assert(length <= capacity);
    assert(out[length] == 0);
}

/// Offers Discord the devices a manufacturer certifies, in the order it should prefer them.
pub export fn discord_client_set_certified_devices(
    client: *Handle,
    devices: ?[*]const ForeignCertifiedDevice,
    device_count: c_int,
) ClientStatus {
    const self = client.resolve() orelse return .invalid;

    if (device_count < 0) return .invalid;
    if (device_count > rpc.CertifiedDevice.capacity) return .invalid;
    const offered: usize = @intCast(device_count);
    if (offered > 0 and devices == null) return .invalid;

    var related: [rpc.CertifiedDevice.capacity][rpc.CertifiedDevice.related_capacity][]const u8 =
        undefined;
    var gathered: [rpc.CertifiedDevice.capacity]rpc.CertifiedDevice = undefined;

    const given = if (devices) |entries| entries[0..offered] else &.{};
    for (given, gathered[0..offered], related[0..offered]) |*entry, *device, *slots| {
        device.* = gatherDevice(entry, slots) catch return .invalid;
    }

    self.client.setCertifiedDevices(self.io, gathered[0..offered]) catch |err| {
        return argumentStatus(err);
    };
    return .ok;
}

/// A key list wider than a binding carries is refused where the count is read.
fn gatherShortcut(
    out: *[rpc.VoiceSettings.shortcut_capacity]rpc.VoiceSettings.Shortcut,
    update: *const ForeignVoiceUpdate,
) error{Invalid}!?[]const rpc.VoiceSettings.Shortcut {
    if (update.shortcut_count < 0) return null;

    const counted: usize = @intCast(update.shortcut_count);
    if (counted > out.len) return error.Invalid;
    if (counted > 0 and update.shortcut == null) return error.Invalid;

    const keys = if (update.shortcut) |entries| entries[0..counted] else &.{};
    for (keys, out[0..counted]) |*given, *slot| {
        slot.* = .{ .kind = given.kind, .code = given.code, .name = .empty };
        slot.name.set(std.mem.span(given.name orelse ""));
    }
    return out[0..counted];
}

fn gatherDevice(
    entry: *const ForeignCertifiedDevice,
    slots: *[rpc.CertifiedDevice.related_capacity][]const u8,
) error{Invalid}!rpc.CertifiedDevice {
    if (entry.related_count < 0) return error.Invalid;

    const counted: usize = @intCast(entry.related_count);
    if (counted > slots.len) return error.Invalid;
    if (counted > 0 and entry.related == null) return error.Invalid;

    const listed = if (entry.related) |ids| ids[0..counted] else &.{};
    for (listed, slots[0..counted]) |id, *slot| {
        slot.* = std.mem.span(id orelse return error.Invalid);
    }

    return .{
        .kind = spoken(rpc.CertifiedDevice.Kind, entry.kind) orelse return error.Invalid,
        .id = optional(entry.id) orelse return error.Invalid,
        .vendor_name = optional(entry.vendor_name) orelse return error.Invalid,
        .vendor_url = optional(entry.vendor_url) orelse return error.Invalid,
        .model_name = optional(entry.model_name) orelse return error.Invalid,
        .model_url = optional(entry.model_url) orelse return error.Invalid,
        .related = slots[0..counted],
        .echo_cancellation = pointed(bool, entry.echo_cancellation),
        .noise_suppression = pointed(bool, entry.noise_suppression),
        .automatic_gain_control = pointed(bool, entry.automatic_gain_control),
        .hardware_mute = pointed(bool, entry.hardware_mute),
    };
}

/// A null pointer is the absent value C has no other spelling for.
fn pointed(comptime Held: type, given: ?*const Held) ?Held {
    return (given orelse return null).*;
}

fn voiceMode(given: ?*const c_int) ?rpc.VoiceSettings.Mode.Kind {
    return spoken(rpc.VoiceSettings.Mode.Kind, pointed(c_int, given) orelse return null);
}

fn status(err: Client.PresenceError) ClientStatus {
    return switch (err) {
        error.InvalidPresence => .presence_invalid,
        error.PayloadTooLarge => .payload_too_large,
        error.Canceled => .canceled,
    };
}

fn optional(value: ?[*:0]const u8) ?[]const u8 {
    return std.mem.span(value orelse return null);
}

/// A negative party size has no meaning on the wire.
fn count(value: c_int) u32 {
    return if (value < 0) 0 else @intCast(value);
}

/// Anything unrecognized is the closed party a zeroed struct asks for.
fn privacy(value: c_int) Presence.Privacy {
    return if (value == @backingInt(Privacy.public)) .public else .private;
}

/// Discord numbers these itself and adds to them, so a value this ABI does not name is carried
/// through as it stands. One no byte can hold is the activity a zeroed struct asks for.
fn activityType(value: c_int) Presence.ActivityType {
    const held = std.math.cast(u8, value) orelse return .playing;
    return @fromBackingInt(held);
}

/// A NUL-terminated copy, since this API carries lengths and C wants sentinels.
fn Terminated(comptime capacity: u32) type {
    return struct {
        bytes: [capacity + 1]u8,

        const Self = @This();

        /// Filled where it lies: returning one of these by value would copy the whole array
        /// for a string that is usually a few bytes of it.
        fn set(self: *Self, value: []const u8) void {
            const length = @min(value.len, capacity);
            @memcpy(self.bytes[0..length], value[0..length]);
            self.bytes[length] = 0;

            assert(length <= capacity);
            assert(self.bytes[length] == 0);
        }

        fn text(self: *const Self) [*:0]const u8 {
            // The cast is unbounded, so the sentinel is confirmed within the array first.
            assert(std.mem.indexOfScalar(u8, &self.bytes, 0) != null);
            return @ptrCast(&self.bytes);
        }
    };
}

/// Filled in place, like `EventStorage`: the struct handed out points into this.
const VoiceStorage = struct {
    input: ChannelStorage,
    output: ChannelStorage,
    key_names: [shortcut_capacity]KeyText,
    shortcut: [shortcut_capacity]ForeignShortcut,

    const device_capacity = rpc.VoiceSettings.device_capacity;
    const shortcut_capacity = rpc.VoiceSettings.shortcut_capacity;
    const DeviceText = Terminated(rpc.VoiceSettings.device_bytes);
    const KeyText = Terminated(rpc.VoiceSettings.key_name_bytes);

    const ChannelStorage = struct {
        device_id: DeviceText,
        ids: [device_capacity]DeviceText,
        names: [device_capacity]DeviceText,
        devices: [device_capacity]ForeignDevice,
    };

    fn fill(
        self: *VoiceStorage,
        out: *ForeignVoiceSettings,
        settings: *const rpc.VoiceSettings,
    ) void {
        out.* = std.mem.zeroes(ForeignVoiceSettings);

        fillDirection(&self.input, &out.input, &settings.input);
        fillDirection(&self.output, &out.output, &settings.output);

        const counted = @min(settings.mode.shortcut_count, shortcut_capacity);
        for (self.shortcut[0..counted], self.key_names[0..counted], 0..) |*slot, *name, index| {
            const held = settings.mode.shortcut[index];
            name.*.set(held.name.slice());
            slot.* = .{ .kind = held.kind, .code = held.code, .name = name.text() };
        }

        out.mode = .{
            .kind = @backingInt(settings.mode.kind),
            .auto_threshold = settings.mode.auto_threshold,
            .threshold = settings.mode.threshold,
            .delay = settings.mode.delay,
            .shortcut = &self.shortcut,
            .shortcut_count = @intCast(counted),
        };
        out.automatic_gain_control = settings.automatic_gain_control;
        out.echo_cancellation = settings.echo_cancellation;
        out.noise_suppression = settings.noise_suppression;
        out.qos = settings.qos;
        out.silence_warning = settings.silence_warning;
        out.deaf = settings.deaf;
        out.mute = settings.mute;
    }

    fn fillDirection(
        self: *ChannelStorage,
        out: *ForeignVoiceChannel,
        channel: *const rpc.VoiceSettings.Direction,
    ) void {
        self.device_id.set(channel.device_id.slice());

        const counted = @min(channel.device_count, device_capacity);
        for (
            self.devices[0..counted],
            self.ids[0..counted],
            self.names[0..counted],
            0..,
        ) |*device, *id, *name, index| {
            id.*.set(channel.devices[index].id.slice());
            name.*.set(channel.devices[index].name.slice());
            device.* = .{ .id = id.text(), .name = name.text() };
        }

        out.* = .{
            .device_id = self.device_id.text(),
            .volume = channel.volume,
            .devices = &self.devices,
            .device_count = @intCast(counted),
        };
    }
};

const Message = Terminated(@FieldType(Client.Status, "message").capacity_bytes);
const Secret = Terminated(Client.Secret.capacity_bytes);

/// Filled in place: `out` points into this, so a copy would carry pointers back into whatever
/// it was copied from.
const EventStorage = struct {
    id: Terminated(User.capacityOf("id")),
    username: Terminated(User.capacityOf("username")),
    discriminator: Terminated(User.capacityOf("discriminator")),
    avatar: Terminated(User.capacityOf("avatar")),
    message: Message,
    secret: Secret,
    channel_id: Terminated(rpc.snowflake_bytes),
    guild_id: Terminated(rpc.snowflake_bytes),
    name: Terminated(rpc.Guild.name_bytes),
    title: Terminated(rpc.Payload.title_bytes),
    body: Terminated(rpc.Payload.content_bytes),

    /// The event is read where the caller keeps it, since a notice is as wide as the widest
    /// payload the protocol carries.
    fn fill(self: *EventStorage, out: *ForeignEvent, event: *const Client.Event) void {
        out.* = std.mem.zeroes(ForeignEvent);

        switch (event.*) {
            .ready => |*user| {
                out.kind = @backingInt(EventKind.ready);
                self.fillUser(&out.user, user.*);
            },
            .join_request => |*user| {
                out.kind = @backingInt(EventKind.join_request);
                self.fillUser(&out.user, user.*);
            },
            .disconnected => |*report| {
                out.kind = @backingInt(EventKind.disconnected);
                out.code = report.code;
                self.message.set(report.message.slice());
                out.message = self.message.text();
            },
            .errored => |*report| {
                out.kind = @backingInt(EventKind.errored);
                out.code = report.code;
                self.message.set(report.message.slice());
                out.message = self.message.text();
            },
            .join_game => |*secret| {
                out.kind = @backingInt(EventKind.join_game);
                self.secret.set(secret.slice());
                out.secret = self.secret.text();
            },
            .spectate_game => |*secret| {
                out.kind = @backingInt(EventKind.spectate_game);
                self.secret.set(secret.slice());
                out.secret = self.secret.text();
            },
            .notice => |*notice| {
                out.kind = @backingInt(EventKind.notice);
                out.subscribed = @backingInt(notice.event);
                out.shape = @backingInt(@as(rpc.Payload.Shape, notice.payload));
                self.fillNotice(out, &notice.payload);
            },
        }
        assert(out.kind >= @backingInt(EventKind.ready));
        assert(out.kind <= @backingInt(EventKind.notice));
    }

    /// Each shape fills the fields it names, and `code` carries whatever numbering
    /// the payload puts on itself.
    fn fillNotice(self: *EventStorage, out: *ForeignEvent, payload: *const rpc.Payload) void {
        switch (payload.*) {
            .none => {},
            .user => |user| self.fillUser(&out.user, user),
            .relationship => |relationship| {
                out.code = relationship.kind;
                self.fillUser(&out.user, relationship.user);
            },
            .guild => |named| {
                self.channel_id.set(named.id.slice());
                self.name.set(named.name.slice());
                out.channel_id = self.channel_id.text();
                out.name = self.name.text();
            },
            .channel => |summary| {
                out.code = @backingInt(summary.kind);
                self.channel_id.set(summary.id.slice());
                self.name.set(summary.name.slice());
                out.channel_id = self.channel_id.text();
                out.name = self.name.text();
            },
            .voice_channel => |selected| {
                self.channel_id.set(selected.channel_id.slice());
                self.guild_id.set(selected.guild_id.slice());
                out.channel_id = self.channel_id.text();
                out.guild_id = self.guild_id.text();
            },
            .voice_state => |state| {
                out.code = @intCast(state.volume);
                self.name.set(state.nick.slice());
                out.name = self.name.text();
                self.fillUser(&out.user, state.user);
            },
            .connection => |connection| {
                out.code = connection.average_ping;
                self.name.set(connection.state.slice());
                self.body.set(connection.hostname.slice());
                out.name = self.name.text();
                out.body = self.body.text();
            },
            .speaking => |speaking| {
                self.channel_id.set(speaking.user_id.slice());
                out.channel_id = self.channel_id.text();
            },
            .message => |message| {
                self.channel_id.set(message.channel_id.slice());
                self.name.set(message.nick.slice());
                self.body.set(message.content.slice());
                out.channel_id = self.channel_id.text();
                out.name = self.name.text();
                out.body = self.body.text();
                self.fillUser(&out.user, message.author);
            },
            .notification => |notification| {
                self.channel_id.set(notification.channel_id.slice());
                self.title.set(notification.title.slice());
                self.body.set(notification.body.slice());
                self.name.set(notification.icon_url.slice());
                out.channel_id = self.channel_id.text();
                out.title = self.title.text();
                out.body = self.body.text();
                out.name = self.name.text();
                self.fillUser(&out.user, notification.author);
            },
            .invite => |invite| {
                out.code = invite.kind;
                self.channel_id.set(invite.channel_id.slice());
                self.guild_id.set(invite.message_id.slice());
                out.channel_id = self.channel_id.text();
                out.guild_id = self.guild_id.text();
                self.fillUser(&out.user, invite.user);
            },
            .entitlement => |entitlement| {
                self.channel_id.set(entitlement.id.slice());
                self.guild_id.set(entitlement.sku_id.slice());
                out.channel_id = self.channel_id.text();
                out.guild_id = self.guild_id.text();
            },
        }
    }

    fn fillUser(self: *EventStorage, out: *ForeignUser, value: User) void {
        assert(value.id.len <= User.capacityOf("id"));
        self.id.set(value.id.slice());
        self.username.set(value.username.slice());
        self.discriminator.set(value.discriminator.slice());
        self.avatar.set(value.avatar.slice());
        assert(self.id.bytes[value.id.len] == 0);
        out.* = .{
            .user_id = self.id.text(),
            .username = self.username.text(),
            .discriminator = self.discriminator.text(),
            .avatar = self.avatar.text(),
        };
    }
};
