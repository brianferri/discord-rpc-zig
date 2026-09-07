//! The RPC layer: frames on the wire, and the command payloads that travel in them.

const std = @import("std");
const assert = std.debug.assert;

const text = @import("../text.zig");
const User = @import("../User.zig");

pub const Connection = @import("Connection.zig");
pub const parse = @import("parse.zig");
pub const serialize = @import("serialize.zig");

/// The widest decimal a `u32` nonce spells. One side writes it and the other reads it back,
/// so it is held here where both meet.
pub const nonce_digits = 10;

comptime {
    assert(nonce_digits >= "4294967295".len);
}

/// The widest decimal a Discord id spells.
pub const snowflake_bytes = 20;

comptime {
    assert(snowflake_bytes >= "18446744073709551615".len);
}

/// The two frames that arrive unasked for, and the wrapper every subscribed event travels in.
pub const dispatch = "DISPATCH";
pub const ready = "READY";
pub const errored = "ERROR";

/// Everything Discord will forward once asked. One side writes the name into a `SUBSCRIBE` and
/// the other matches it on the way back, so the spelling is held here where both meet.
pub const Event = enum {
    current_user_update,
    relationship_update,
    guild_status,
    guild_create,
    channel_create,
    voice_channel_select,
    voice_state_create,
    voice_state_update,
    voice_state_delete,
    voice_settings_update,
    voice_connection_status,
    speaking_start,
    speaking_stop,
    message_create,
    message_update,
    message_delete,
    notification_create,
    activity_join,
    activity_spectate,
    activity_join_request,
    activity_invite,
    entitlement_create,
    entitlement_delete,

    /// The object a subscription is keyed by. Discord refuses a keyed event offered no key,
    /// and an unkeyed one offered a key.
    pub const Scope = enum { global, guild, channel };

    pub fn name(subscribed: Event) []const u8 {
        return switch (subscribed) {
            .current_user_update => "CURRENT_USER_UPDATE",
            .relationship_update => "RELATIONSHIP_UPDATE",
            .guild_status => "GUILD_STATUS",
            .guild_create => "GUILD_CREATE",
            .channel_create => "CHANNEL_CREATE",
            .voice_channel_select => "VOICE_CHANNEL_SELECT",
            .voice_state_create => "VOICE_STATE_CREATE",
            .voice_state_update => "VOICE_STATE_UPDATE",
            .voice_state_delete => "VOICE_STATE_DELETE",
            .voice_settings_update => "VOICE_SETTINGS_UPDATE",
            .voice_connection_status => "VOICE_CONNECTION_STATUS",
            .speaking_start => "SPEAKING_START",
            .speaking_stop => "SPEAKING_STOP",
            .message_create => "MESSAGE_CREATE",
            .message_update => "MESSAGE_UPDATE",
            .message_delete => "MESSAGE_DELETE",
            .notification_create => "NOTIFICATION_CREATE",
            .activity_join => "ACTIVITY_JOIN",
            .activity_spectate => "ACTIVITY_SPECTATE",
            .activity_join_request => "ACTIVITY_JOIN_REQUEST",
            .activity_invite => "ACTIVITY_INVITE",
            .entitlement_create => "ENTITLEMENT_CREATE",
            .entitlement_delete => "ENTITLEMENT_DELETE",
        };
    }

    /// Which `Payload` this event arrives carrying.
    pub fn shape(subscribed: Event) Payload.Shape {
        return switch (subscribed) {
            .current_user_update => .user,
            .relationship_update => .relationship,
            .guild_status, .guild_create => .guild,
            .channel_create => .channel,
            .voice_channel_select => .voice_channel,
            .voice_state_create, .voice_state_update, .voice_state_delete => .voice_state,
            .voice_connection_status => .connection,
            .speaking_start, .speaking_stop => .speaking,
            .message_create, .message_update, .message_delete => .message,
            .notification_create => .notification,
            .activity_invite => .invite,
            .entitlement_create, .entitlement_delete => .entitlement,

            // A settings change says only that it happened, since the settings themselves are
            // wider than an event queue carries; `Client.voiceSettings` reads them back.
            .voice_settings_update => .none,

            // These three reach a caller as events of their own.
            .activity_join, .activity_spectate, .activity_join_request => .none,
        };
    }

    pub fn scope(subscribed: Event) Scope {
        return switch (subscribed) {
            .guild_status => .guild,
            .voice_state_create,
            .voice_state_update,
            .voice_state_delete,
            .speaking_start,
            .speaking_stop,
            .message_create,
            .message_update,
            .message_delete,
            => .channel,
            else => .global,
        };
    }

    /// The event that spelling names, or null for one this client never asks for.
    pub fn fromName(spelling: []const u8) ?Event {
        return named(Event, spelling);
    }
};

/// The value whose wire name matches, or null. Every enum that spells itself on the wire is
/// read back through here.
fn named(comptime Named: type, spelling: []const u8) ?Named {
    inline for (std.enums.values(Named)) |candidate| {
        const name = comptime candidate.name();
        if (spelling.len == name.len and std.mem.eql(u8, spelling, name)) return candidate;
    }
    return null;
}

/// How Discord reports the local voice configuration. The device lists enumerate what the
/// machine offers, which is why `Update` has no say in them.
pub const VoiceSettings = struct {
    input: Direction = .{},
    output: Direction = .{},
    mode: Mode = .{},
    automatic_gain_control: bool = false,
    echo_cancellation: bool = false,
    noise_suppression: bool = false,
    qos: bool = false,
    silence_warning: bool = false,
    deaf: bool = false,
    mute: bool = false,

    /// A device id or the name shown for it.
    pub const device_bytes = 64;

    /// Devices kept per direction. Discord lists every one the machine offers, and
    /// `device_count` says how many of them fit.
    pub const device_capacity = 8;

    /// Keys in a push-to-talk binding.
    pub const shortcut_capacity = 4;
    pub const key_name_bytes = 32;

    /// One side of the local audio path, and the devices that side can use.
    pub const Direction = struct {
        device_id: text.Buffer(device_bytes) = .empty,
        volume: f32 = 0,
        devices: [device_capacity]Device = @splat(.{}),
        device_count: u32 = 0,
    };

    pub const Device = struct {
        id: text.Buffer(device_bytes) = .empty,
        name: text.Buffer(device_bytes) = .empty,
    };

    pub const Mode = struct {
        kind: Kind = .voice_activity,
        auto_threshold: bool = false,
        /// In decibels, from -100 to 0.
        threshold: f32 = 0,
        /// The push-to-talk release delay, in milliseconds, up to 2000.
        delay: f32 = 0,
        shortcut: [shortcut_capacity]Shortcut = @splat(.{}),
        shortcut_count: u32 = 0,

        pub const Kind = enum {
            push_to_talk,
            voice_activity,

            pub fn name(kind: Kind) []const u8 {
                return switch (kind) {
                    .push_to_talk => "PUSH_TO_TALK",
                    .voice_activity => "VOICE_ACTIVITY",
                };
            }

            pub fn fromName(spelling: []const u8) ?Kind {
                return named(Kind, spelling);
            }
        };
    };

    /// One key in a push-to-talk binding. `kind` is Discord's own numbering: 0 keyboard key,
    /// 1 mouse button, 2 keyboard modifier, 3 gamepad button.
    pub const Shortcut = struct {
        kind: i32 = 0,
        code: i32 = 0,
        name: text.Buffer(key_name_bytes) = .empty,
    };

    /// What a caller changes. A field left null keeps the value Discord holds.
    pub const Update = struct {
        input_device_id: ?[]const u8 = null,
        /// From 0 to 100.
        input_volume: ?f32 = null,
        output_device_id: ?[]const u8 = null,
        /// From 0 to 200.
        output_volume: ?f32 = null,
        mode: ?Mode.Kind = null,
        mode_auto_threshold: ?bool = null,
        mode_threshold: ?f32 = null,
        mode_delay: ?f32 = null,
        shortcut: ?[]const Shortcut = null,
        automatic_gain_control: ?bool = null,
        echo_cancellation: ?bool = null,
        noise_suppression: ?bool = null,
        qos: ?bool = null,
        silence_warning: ?bool = null,
        deaf: ?bool = null,
        mute: ?bool = null,
    };

    pub const empty: VoiceSettings = .{};
};

/// One user's mix in the local client. Every field is optional in both directions: a caller
/// sets what it means to change, and Discord answers with what it applied.
pub const UserVoiceSettings = struct {
    /// Each from 0.0 to 1.0.
    pan_left: ?f32 = null,
    pan_right: ?f32 = null,
    /// From 0 to `volume_max`, where 100 is the level Discord starts at.
    volume: ?u32 = null,
    mute: ?bool = null,

    pub const volume_max = 200;
    pub const empty: UserVoiceSettings = .{};
};

/// What a subscribed event arrives carrying. `Event.shape` names which one an event uses, and
/// the events that reach a caller as `Client.Event` variants of their own carry `none` here.
pub const Payload = union(Shape) {
    none,
    user: User,
    relationship: Relationship,
    guild: Named,
    channel: Channel.Summary,
    voice_channel: VoiceChannel,
    voice_state: VoiceState,
    connection: VoiceConnection,
    speaking: Speaking,
    message: Message,
    notification: Notification,
    invite: Invite,
    entitlement: Entitlement,

    pub const Shape = enum {
        none,
        user,
        relationship,
        guild,
        channel,
        voice_channel,
        voice_state,
        connection,
        speaking,
        message,
        notification,
        invite,
        entitlement,
    };

    /// A message's text, held to what an event queue carries. A longer one is truncated.
    pub const content_bytes = 256;
    pub const title_bytes = 128;
    pub const url_bytes = 128;

    /// Something named by an id, which is all a guild reports on its own.
    pub const Named = struct {
        id: text.Buffer(snowflake_bytes) = .empty,
        name: text.Buffer(Guild.name_bytes) = .empty,
    };

    /// `kind` is Discord's own numbering: 1 friend, 2 blocked, 3 pending in, 4 pending out.
    pub const Relationship = struct {
        kind: i32 = 0,
        user: User = .empty,
    };

    pub const VoiceChannel = struct {
        channel_id: text.Buffer(snowflake_bytes) = .empty,
        guild_id: text.Buffer(snowflake_bytes) = .empty,
    };

    pub const VoiceConnection = struct {
        /// Discord's own spelling, among them `DISCONNECTED`, `CONNECTING` and `CONNECTED`.
        state: text.Buffer(state_bytes) = .empty,
        hostname: text.Buffer(hostname_bytes) = .empty,
        average_ping: i32 = 0,
        last_ping: i32 = 0,

        pub const state_bytes = 32;
        pub const hostname_bytes = 64;
    };

    pub const Speaking = struct {
        user_id: text.Buffer(snowflake_bytes) = .empty,
    };

    pub const Message = struct {
        channel_id: text.Buffer(snowflake_bytes) = .empty,
        id: text.Buffer(snowflake_bytes) = .empty,
        author: User = .empty,
        nick: text.Buffer(VoiceState.nick_bytes) = .empty,
        content: text.Buffer(content_bytes) = .empty,
    };

    pub const Notification = struct {
        channel_id: text.Buffer(snowflake_bytes) = .empty,
        title: text.Buffer(title_bytes) = .empty,
        body: text.Buffer(content_bytes) = .empty,
        icon_url: text.Buffer(url_bytes) = .empty,
        author: User = .empty,
    };

    /// `kind` is Discord's own numbering: 1 join, 2 spectate, 3 listen.
    pub const Invite = struct {
        kind: i32 = 0,
        user: User = .empty,
        channel_id: text.Buffer(snowflake_bytes) = .empty,
        message_id: text.Buffer(snowflake_bytes) = .empty,
    };

    pub const Entitlement = struct {
        id: text.Buffer(snowflake_bytes) = .empty,
        sku_id: text.Buffer(snowflake_bytes) = .empty,
    };
};

/// A guild the user is in.
pub const Guild = struct {
    id: text.Buffer(snowflake_bytes) = .empty,
    name: text.Buffer(name_bytes) = .empty,
    icon_url: text.Buffer(url_bytes) = .empty,

    pub const name_bytes = 100;
    pub const url_bytes = 256;
    pub const empty: Guild = .{};
};

/// What `GET_GUILDS` reports. Discord lists every guild the user is in, and `count` says how
/// many of them fit.
pub const GuildList = struct {
    guilds: [capacity]Guild = @splat(.empty),
    count: u32 = 0,

    pub const capacity = 32;
    pub const empty: GuildList = .{};
};

/// One person in a voice channel, with the local mix applied to them.
pub const VoiceState = struct {
    user: User = .empty,
    nick: text.Buffer(nick_bytes) = .empty,
    /// As the guild has them.
    mute: bool = false,
    deaf: bool = false,
    /// As they have themselves.
    self_mute: bool = false,
    self_deaf: bool = false,
    suppress: bool = false,
    /// The local client's own mix for this person.
    locally_muted: bool = false,
    volume: u32 = 0,
    pan_left: f32 = 0,
    pan_right: f32 = 0,

    pub const nick_bytes = 64;
    pub const empty: VoiceState = .{};
};

/// A channel, as the channel commands report it. A voice channel names who is in it.
pub const Channel = struct {
    /// Set when Discord named a channel. A caller that left one is answered with none.
    found: bool = false,
    id: text.Buffer(snowflake_bytes) = .empty,
    guild_id: text.Buffer(snowflake_bytes) = .empty,
    name: text.Buffer(name_bytes) = .empty,
    kind: Kind = .guild_text,
    topic: text.Buffer(topic_bytes) = .empty,
    bitrate: i32 = 0,
    /// Zero stands for a voice channel that takes as many as arrive.
    user_limit: i32 = 0,
    position: i32 = 0,
    voice_states: [voice_state_capacity]VoiceState = @splat(.empty),
    voice_state_count: u32 = 0,

    pub const name_bytes = 100;
    pub const topic_bytes = 256;
    pub const voice_state_capacity = 16;

    /// Discord's own numbering, left open because it adds kinds.
    pub const Kind = enum(i32) {
        guild_text = 0,
        dm = 1,
        guild_voice = 2,
        group_dm = 3,
        _,
    };

    /// What names a channel, which is what a list of them carries and what a channel reports
    /// when it is created.
    pub const Summary = struct {
        id: text.Buffer(snowflake_bytes) = .empty,
        name: text.Buffer(name_bytes) = .empty,
        kind: Kind = .guild_text,
    };

    pub const empty: Channel = .{};
};

/// What `GET_CHANNELS` reports: what names each channel, without what a whole one carries.
pub const ChannelList = struct {
    channels: [capacity]Channel.Summary = @splat(.{}),
    count: u32 = 0,

    pub const capacity = 64;
    pub const empty: ChannelList = .{};
};

/// A device a manufacturer certifies, offered to Discord in order of priority.
///
/// Text is held to printable ASCII and to `text_bytes`, which is what keeps a whole list
/// inside the command buffer it is written into.
pub const CertifiedDevice = struct {
    kind: Kind,
    /// The device's Windows UUID.
    id: []const u8,
    vendor_name: []const u8,
    vendor_url: []const u8,
    model_name: []const u8,
    model_url: []const u8,
    /// UUIDs of the devices this one belongs with.
    related: []const []const u8 = &.{},
    echo_cancellation: ?bool = null,
    noise_suppression: ?bool = null,
    automatic_gain_control: ?bool = null,
    hardware_mute: ?bool = null,

    pub const Kind = enum {
        audio_input,
        audio_output,
        video_input,

        pub fn name(kind: Kind) []const u8 {
            return switch (kind) {
                .audio_input => "audioinput",
                .audio_output => "audiooutput",
                .video_input => "videoinput",
            };
        }
    };

    pub const capacity = 4;
    pub const related_capacity = 2;
    pub const text_bytes = 48;
};

test "every event name survives the round trip" {
    for (std.enums.values(Event)) |subscribed| {
        const spelling = subscribed.name();
        try std.testing.expect(spelling.len > 0);
        try std.testing.expectEqual(subscribed, Event.fromName(spelling).?);
    }

    // The two unsubscribable frames must never resolve to a subscription.
    try std.testing.expectEqual(null, Event.fromName(ready));
    try std.testing.expectEqual(null, Event.fromName(errored));
    try std.testing.expectEqual(null, Event.fromName(dispatch));
    try std.testing.expectEqual(null, Event.fromName(""));
}

// A key travels in the argument the scope names, so the two must not drift apart.
test "only the keyed events carry a scope" {
    try std.testing.expectEqual(Event.Scope.guild, Event.guild_status.scope());
    try std.testing.expectEqual(Event.Scope.channel, Event.message_create.scope());
    try std.testing.expectEqual(Event.Scope.global, Event.activity_join.scope());
}

test {
    _ = Connection;
    _ = parse;
    _ = serialize;
}
