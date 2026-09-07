//! Reading the wire form. A frame is walked once and copied out as it goes; a field that is
//! missing or of the wrong kind is left at its default.

const std = @import("std");
const assert = std.debug.assert;

const text = @import("../text.zig");
const User = @import("../User.zig");
const rpc = @import("root.zig");

const json = @import("../json/root.zig");
const Scanner = json.Scanner;
const scan = json.scan;

/// The payload is in hand before the walk starts, so refusing it is the only way to fail.
pub const Error = Scanner.Error;

const command_bytes = 32;
pub const text_bytes = 256;

/// The one-time code `AUTHORIZE` answers with, which the caller trades for a token elsewhere.
pub const authorization_bytes = 128;

/// `code` and `message` reach the top level on a close frame and `data` on an `ERROR` event;
/// a frame carrying both is answered with the `data` copy, whatever the member order.
///
/// A repeated member is answered with its last occurrence, and a repeated object
/// with that occurrence alone.
pub const Frame = struct {
    command: text.Buffer(command_bytes) = .empty,
    event: text.Buffer(command_bytes) = .empty,
    has_nonce: bool = false, // set on a response, absent on an event Discord raised itself
    /// The nonce this client sent, echoed back; a waiting request matches on it. Nonces start
    /// at one, so zero is what a reply carries when it belongs elsewhere.
    nonce: u32 = 0,
    code: i32 = 0,
    message: text.Buffer(text_bytes) = .empty,
    secret: text.Buffer(text_bytes) = .empty,
    /// Set when `data.code` arrived as a string, which is how `AUTHORIZE` answers.
    authorization: text.Buffer(authorization_bytes) = .empty,
    user: User = .empty,
    has_user: bool = false,

    /// Which of the two `data` supplied; a top-level copy arriving later is passed over.
    from_data: packed struct(u8) {
        code: bool = false,
        message: bool = false,
        unused: u6 = 0,
    } = .{},

    pub const empty: Frame = .{};
};

/// Where a reply too wide for `Frame` is decoded. The caller waiting on the reply owns the
/// storage, so a walk through one of these reaches only as far as that caller's own wait.
pub const Sink = union(enum) {
    voice_settings: *rpc.VoiceSettings,
    user_voice_settings: *rpc.UserVoiceSettings,
    guilds: *rpc.GuildList,
    guild: *rpc.Guild,
    channels: *rpc.ChannelList,
    channel: *rpc.Channel,
    /// What a subscribed event carries, which the event itself says the shape of.
    notice: struct { event: rpc.Event, out: *rpc.Payload },
};

/// The longest single value a walk will gather, counted in bytes.
pub const max_value_bytes: u32 = 64 * 1024;

const max_members: u32 = max_value_bytes;

/// A key longer than this is truncated, and so matches no member this protocol names.
const max_key_bytes = 32;

/// The scanner, with each step's failure classified.
///
/// The payload is complete before the walk starts, so the scanner passes a value over whole.
const Walk = struct {
    reader: *Scanner,

    fn next(walk: Walk) Error!Scanner.Kind {
        return walk.reader.next();
    }

    fn peek(walk: Walk) Error!Scanner.Kind {
        return walk.reader.peek();
    }

    fn skipUntil(walk: Walk, height: u32) Error!void {
        return walk.reader.skipUntil(height);
    }

    fn stackHeight(walk: Walk) u32 {
        return walk.reader.stackHeight();
    }

    fn skip(walk: Walk) Error!void {
        return walk.reader.skipValue();
    }

    /// The bytes the last string or number carried, as the payload spells them.
    fn value(walk: Walk) []const u8 {
        return walk.reader.value;
    }

    /// Whether the last string holds an escape, so its text costs a pass to read.
    fn escaped(walk: Walk) bool {
        return walk.reader.escaped;
    }
};

const Members = struct {
    walk: *Walk,
    seen: u32 = 0,
    /// A key split across refills is gathered here.
    key: text.Buffer(max_key_bytes) = .empty,

    fn next(members: *Members) Error!?[]const u8 {
        if (members.seen == max_members) return error.BadPayload;
        members.seen += 1;

        switch (try members.walk.next()) {
            .object_end => return null,
            .string => {},
            else => return error.BadPayload,
        }

        // A name Discord spells plainly is the payload's own bytes, so matching it costs no
        // copy at all. Only an escape needs somewhere to be resolved into.
        const raw = members.walk.value();
        if (!members.walk.escaped()) return raw;

        var decoded: [max_key_bytes]u8 = undefined;
        const length = try Scanner.unescape(&decoded, raw);
        members.key.set(decoded[0..@min(length, decoded.len)]);
        return members.key.slice();
    }
};

const TopLevel = enum { cmd, evt, nonce, code, message, data, other };
const Data = enum { secret, code, message, user, other };
const Account = enum { id, username, discriminator, avatar, other };
const Voice = enum {
    input,
    output,
    mode,
    automatic_gain_control,
    echo_cancellation,
    noise_suppression,
    qos,
    silence_warning,
    deaf,
    mute,
    other,
};
const VoiceChannel = enum { device_id, volume, available_devices, other };
const VoiceDevice = enum { id, name, other };
const VoiceMode = enum { type, auto_threshold, threshold, shortcut, delay, other };
const VoiceKey = enum { type, code, name, other };
const UserVoice = enum { pan, volume, mute, other };
const Pan = enum { left, right, other };
const Guilds = enum { guilds, other };
const GuildFields = enum { id, name, icon_url, other };
const Channels = enum { channels, other };
const ChannelFields = enum {
    id,
    guild_id,
    name,
    type,
    topic,
    bitrate,
    user_limit,
    position,
    voice_states,
    other,
};
const VoiceStateFields = enum { voice_state, user, nick, volume, mute, pan, other };
const VoiceFlags = enum { mute, deaf, self_mute, self_deaf, suppress, other };
const NamedFields = enum { guild, id, name, other };
const Relationship = enum { type, user, other };
const Selected = enum { channel_id, guild_id, other };
const Connected = enum { state, hostname, average_ping, last_ping, other };
const Speaking = enum { user_id, other };
const Posted = enum { channel_id, message, other };
const MessageFields = enum { id, content, author, nick, other };
const Notified = enum { channel_id, message, title, body, icon_url, other };
const Invited = enum { type, user, channel_id, message_id, other };
const Entitled = enum { entitlement, id, sku_id, other };

comptime {
    for (.{
        TopLevel,         Data,        Account,       Voice,      VoiceChannel,
        VoiceDevice,      VoiceMode,   VoiceKey,      UserVoice,  Pan,
        Guilds,           Channels,    GuildFields,   VoiceFlags, ChannelFields,
        VoiceStateFields, NamedFields, Relationship,  Selected,   Connected,
        Speaking,         Posted,      MessageFields, Notified,   Invited,
        Entitled,
    }) |Name| for (@typeInfo(Name).@"enum".field_names) |name| assert(name.len < max_key_bytes);
}

/// A key is settled by its length before any of it is compared, which is what a map keyed on
/// the whole string cannot do: the protocol's member names collide little on length.
fn match(comptime Name: type, key: []const u8) Name {
    comptime assert(@hasField(Name, "other"));

    inline for (@typeInfo(Name).@"enum".field_names) |name| {
        if (comptime !std.mem.eql(u8, name, "other")) {
            if (key.len == name.len and std.mem.eql(u8, key, name)) return @field(Name, name);
        }
    }
    return .other;
}

/// Walks one frame's payload, which must be the whole of it and nothing after it.
pub fn frame(payload: []const u8) Error!Frame {
    // A value is passed over whole, so the payload holding it is what bounds its size.
    if (payload.len > max_value_bytes) return error.BadPayload;

    var scanner: Scanner = .init(payload);
    var walk: Walk = .{ .reader = &scanner };
    assert(walk.stackHeight() == 0);

    const result = try readFrame(&walk);

    assert(walk.stackHeight() == 0);
    return result;
}

fn readFrame(walk: *Walk) Error!Frame {
    const depth = walk.stackHeight();

    var result: Frame = .empty;
    try expectObjectBegin(walk);
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(TopLevel, key)) {
            .cmd => try readString(command_bytes, &result.command, walk),
            .evt => try readString(command_bytes, &result.event, walk),
            .nonce => try readNonce(&result, walk),
            // `data` wins for both.
            .code => if (result.from_data.code)
                try walk.skip()
            else {
                result.code = try readInteger(walk);
            },
            .message => if (result.from_data.message)
                try walk.skip()
            else
                try readString(text_bytes, &result.message, walk),
            .data => try readData(&result, walk),
            .other => try walk.skip(),
        }
    }

    // The walk must end where the bytes do; a second document may not ride along.
    switch (try walk.next()) {
        .end_of_document => {},
        else => return error.BadPayload,
    }

    assert(walk.stackHeight() == depth);
    return result;
}

fn readData(result: *Frame, walk: *Walk) Error!void {
    // Surrendered before the member is read, so a later occurrence answers for all of it.
    result.secret.clear();
    result.authorization.clear();
    result.user = .empty;
    result.has_user = false;
    if (result.from_data.code) result.code = 0;
    if (result.from_data.message) result.message.clear();
    result.from_data = .{};

    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(Data, key)) {
            .secret => try readIdentifier(text_bytes, &result.secret, walk),
            // `AUTHORIZE` answers with a string here where an error answers with a number,
            // so the kind decides which field the value lands in.
            .code => if ((try walk.peek()) == .string) {
                try readIdentifier(authorization_bytes, &result.authorization, walk);
            } else {
                result.code = try readInteger(walk);
                result.from_data.code = true;
            },
            .message => {
                try readString(text_bytes, &result.message, walk);
                result.from_data.message = true;
            },
            .user => result.has_user = try readUser(&result.user, walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

/// Answers whether an account was there to read.
fn readUser(out: *User, walk: *Walk) Error!bool {
    out.* = .empty;

    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return false;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(Account, key)) {
            .id => try readIdentifier(User.capacityOf("id"), &out.id, walk),
            .username => try readString(User.capacityOf("username"), &out.username, walk),
            .discriminator => try readString(
                User.capacityOf("discriminator"),
                &out.discriminator,
                walk,
            ),
            .avatar => try readString(User.capacityOf("avatar"), &out.avatar, walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
    return true;
}

/// Walks a payload again for the part of a reply `Frame` has no room for. `frame` has already
/// taken the fields it holds, so nothing here is read twice.
pub fn into(sink: Sink, payload: []const u8) Error!void {
    if (payload.len > max_value_bytes) return error.BadPayload;

    var scanner: Scanner = .init(payload);
    var walk: Walk = .{ .reader = &scanner };
    assert(walk.stackHeight() == 0);

    try readInto(sink, &walk);

    assert(walk.stackHeight() == 0);
}

fn readInto(sink: Sink, walk: *Walk) Error!void {
    const depth = walk.stackHeight();

    try expectObjectBegin(walk);
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        if (match(TopLevel, key) != .data) {
            try walk.skip();
            continue;
        }
        switch (sink) {
            .voice_settings => |out| try readVoiceSettings(out, walk),
            .user_voice_settings => |out| try readUserVoiceSettings(out, walk),
            .guilds => |out| try readGuildList(out, walk),
            .guild => |out| _ = try readGuild(out, walk),
            .channels => |out| try readChannelList(out, walk),
            .channel => |out| try readChannel(out, walk),
            .notice => |notice| try readPayload(notice.event, notice.out, walk),
        }
    }

    switch (try walk.next()) {
        .end_of_document => {},
        else => return error.BadPayload,
    }

    assert(walk.stackHeight() == depth);
}

fn readVoiceSettings(out: *rpc.VoiceSettings, walk: *Walk) Error!void {
    out.* = .empty;

    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(Voice, key)) {
            .input => try readVoiceDirection(&out.input, walk),
            .output => try readVoiceDirection(&out.output, walk),
            .mode => try readVoiceMode(&out.mode, walk),
            .automatic_gain_control => out.automatic_gain_control = try readBool(walk),
            .echo_cancellation => out.echo_cancellation = try readBool(walk),
            .noise_suppression => out.noise_suppression = try readBool(walk),
            .qos => out.qos = try readBool(walk),
            .silence_warning => out.silence_warning = try readBool(walk),
            .deaf => out.deaf = try readBool(walk),
            .mute => out.mute = try readBool(walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

fn readVoiceDirection(out: *rpc.VoiceSettings.Direction, walk: *Walk) Error!void {
    const device_bytes = rpc.VoiceSettings.device_bytes;
    out.* = .{};

    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(VoiceChannel, key)) {
            .device_id => try readString(device_bytes, &out.device_id, walk),
            .volume => out.volume = try readNumber(walk),
            .available_devices => try readDevices(out, walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

fn readDevices(out: *rpc.VoiceSettings.Direction, walk: *Walk) Error!void {
    out.devices = @splat(.{});
    out.device_count = try gatherArray(rpc.VoiceSettings.Device, &out.devices, walk, readDevice);
}

fn readDevice(out: *rpc.VoiceSettings.Device, walk: *Walk) Error!bool {
    const device_bytes = rpc.VoiceSettings.device_bytes;
    out.* = .{};

    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return false;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(VoiceDevice, key)) {
            .id => try readString(device_bytes, &out.id, walk),
            .name => try readString(device_bytes, &out.name, walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
    return true;
}

fn readVoiceMode(out: *rpc.VoiceSettings.Mode, walk: *Walk) Error!void {
    out.* = .{};

    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(VoiceMode, key)) {
            .type => {
                var spelling: text.Buffer(max_key_bytes) = .empty;
                try readString(max_key_bytes, &spelling, walk);
                out.kind = rpc.VoiceSettings.Mode.Kind.fromName(spelling.slice()) orelse
                    .voice_activity;
            },
            .auto_threshold => out.auto_threshold = try readBool(walk),
            .threshold => out.threshold = try readNumber(walk),
            .delay => out.delay = try readNumber(walk),
            .shortcut => try readShortcuts(out, walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

/// A binding Discord spells with more keys than fit keeps the ones that do, which
/// is what `shortcut_count` reports.
fn readShortcuts(out: *rpc.VoiceSettings.Mode, walk: *Walk) Error!void {
    out.shortcut = @splat(.{});
    out.shortcut_count = try gatherArray(
        rpc.VoiceSettings.Shortcut,
        &out.shortcut,
        walk,
        readShortcut,
    );
}

fn readShortcut(out: *rpc.VoiceSettings.Shortcut, walk: *Walk) Error!bool {
    const key_name_bytes = rpc.VoiceSettings.key_name_bytes;
    out.* = .{};

    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return false;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(VoiceKey, key)) {
            .type => out.kind = try readInteger(walk),
            .code => out.code = try readInteger(walk),
            .name => try readString(key_name_bytes, &out.name, walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
    return true;
}

fn readUserVoiceSettings(out: *rpc.UserVoiceSettings, walk: *Walk) Error!void {
    out.* = .empty;

    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(UserVoice, key)) {
            .pan => try readPan(&out.pan_left, &out.pan_right, walk),
            .volume => out.volume = volumeLevel(try readNumber(walk)),
            .mute => out.mute = try readBool(walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

/// Discord holds a level to its own ceiling, and the comparisons here are written so a NaN
/// takes the floor with everything else outside the range.
fn volumeLevel(value: f32) u32 {
    const ceiling = rpc.UserVoiceSettings.volume_max;
    if (!(value >= 0)) return 0;
    if (value >= @as(f32, ceiling)) return ceiling;

    assert(value >= 0);
    return @intFromFloat(value);
}

fn readPan(left: *?f32, right: *?f32, walk: *Walk) Error!void {
    left.* = null;
    right.* = null;

    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(Pan, key)) {
            .left => left.* = try readNumber(walk),
            .right => right.* = try readNumber(walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

/// Reads what a subscribed event carries into the shape the event names.
fn readPayload(subscribed: rpc.Event, out: *rpc.Payload, walk: *Walk) Error!void {
    switch (subscribed.shape()) {
        .none => {
            out.* = .none;
            try walk.skip();
        },
        .user => {
            out.* = .{ .user = .empty };
            _ = try readUser(&out.user, walk);
        },
        .relationship => {
            out.* = .{ .relationship = .{} };
            try readRelationship(&out.relationship, walk);
        },
        .guild => {
            out.* = .{ .guild = .{} };
            try readNamed(&out.guild, walk);
        },
        .channel => {
            out.* = .{ .channel = .{} };
            _ = try readSummary(&out.channel, walk);
        },
        .voice_channel => {
            out.* = .{ .voice_channel = .{} };
            try readVoiceChannel(&out.voice_channel, walk);
        },
        .voice_state => {
            out.* = .{ .voice_state = .empty };
            _ = try readVoiceState(&out.voice_state, walk);
        },
        .connection => {
            out.* = .{ .connection = .{} };
            try readVoiceConnection(&out.connection, walk);
        },
        .speaking => {
            out.* = .{ .speaking = .{} };
            try readSpeaking(&out.speaking, walk);
        },
        .message => {
            out.* = .{ .message = .{} };
            try readMessage(&out.message, walk);
        },
        .notification => {
            out.* = .{ .notification = .{} };
            try readNotification(&out.notification, walk);
        },
        .invite => {
            out.* = .{ .invite = .{} };
            try readInvite(&out.invite, walk);
        },
        .entitlement => {
            out.* = .{ .entitlement = .{} };
            try readEntitlement(&out.entitlement, walk);
        },
    }
}

/// A guild names itself under `guild`, and a channel at the top level, so both are read here.
fn readNamed(out: *rpc.Payload.Named, walk: *Walk) Error!void {
    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(NamedFields, key)) {
            .guild => try readNamed(out, walk),
            .id => try readIdentifier(rpc.snowflake_bytes, &out.id, walk),
            .name => try readString(rpc.Guild.name_bytes, &out.name, walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

fn readRelationship(out: *rpc.Payload.Relationship, walk: *Walk) Error!void {
    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(Relationship, key)) {
            .type => out.kind = try readInteger(walk),
            .user => _ = try readUser(&out.user, walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

fn readVoiceChannel(out: *rpc.Payload.VoiceChannel, walk: *Walk) Error!void {
    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(Selected, key)) {
            .channel_id => try readIdentifier(rpc.snowflake_bytes, &out.channel_id, walk),
            .guild_id => try readIdentifier(rpc.snowflake_bytes, &out.guild_id, walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

fn readVoiceConnection(out: *rpc.Payload.VoiceConnection, walk: *Walk) Error!void {
    const Connection = rpc.Payload.VoiceConnection;

    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(Connected, key)) {
            .state => try readString(Connection.state_bytes, &out.state, walk),
            .hostname => try readString(Connection.hostname_bytes, &out.hostname, walk),
            .average_ping => out.average_ping = try readInteger(walk),
            .last_ping => out.last_ping = try readInteger(walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

fn readSpeaking(out: *rpc.Payload.Speaking, walk: *Walk) Error!void {
    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(Speaking, key)) {
            .user_id => try readIdentifier(rpc.snowflake_bytes, &out.user_id, walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

fn readMessage(out: *rpc.Payload.Message, walk: *Walk) Error!void {
    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(Posted, key)) {
            .channel_id => try readIdentifier(rpc.snowflake_bytes, &out.channel_id, walk),
            .message => try readMessageBody(out, walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

fn readMessageBody(out: *rpc.Payload.Message, walk: *Walk) Error!void {
    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(MessageFields, key)) {
            .id => try readIdentifier(rpc.snowflake_bytes, &out.id, walk),
            .content => try readString(rpc.Payload.content_bytes, &out.content, walk),
            .author => _ = try readUser(&out.author, walk),
            .nick => try readString(rpc.VoiceState.nick_bytes, &out.nick, walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

fn readNotification(out: *rpc.Payload.Notification, walk: *Walk) Error!void {
    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(Notified, key)) {
            .channel_id => try readIdentifier(rpc.snowflake_bytes, &out.channel_id, walk),
            .title => try readString(rpc.Payload.title_bytes, &out.title, walk),
            .body => try readString(rpc.Payload.content_bytes, &out.body, walk),
            .icon_url => try readString(rpc.Payload.url_bytes, &out.icon_url, walk),
            .message => try readNotificationAuthor(out, walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

/// A notification names who it is from inside the message that raised it.
fn readNotificationAuthor(out: *rpc.Payload.Notification, walk: *Walk) Error!void {
    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(MessageFields, key)) {
            .author => _ = try readUser(&out.author, walk),
            else => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

fn readInvite(out: *rpc.Payload.Invite, walk: *Walk) Error!void {
    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(Invited, key)) {
            .type => out.kind = try readInteger(walk),
            .user => _ = try readUser(&out.user, walk),
            .channel_id => try readIdentifier(rpc.snowflake_bytes, &out.channel_id, walk),
            .message_id => try readIdentifier(rpc.snowflake_bytes, &out.message_id, walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

/// An entitlement arrives wrapped in a member of its own, and names itself inside it.
fn readEntitlement(out: *rpc.Payload.Entitlement, walk: *Walk) Error!void {
    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(Entitled, key)) {
            .entitlement => try readEntitlement(out, walk),
            .id => try readIdentifier(rpc.snowflake_bytes, &out.id, walk),
            .sku_id => try readIdentifier(rpc.snowflake_bytes, &out.sku_id, walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

fn readGuildList(out: *rpc.GuildList, walk: *Walk) Error!void {
    out.* = .empty;

    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(Guilds, key)) {
            .guilds => try readGuilds(out, walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

fn readGuilds(out: *rpc.GuildList, walk: *Walk) Error!void {
    out.guilds = @splat(.empty);
    out.count = try gatherArray(rpc.Guild, &out.guilds, walk, readGuild);
}

/// Answers whether a guild was there to read.
fn readGuild(out: *rpc.Guild, walk: *Walk) Error!bool {
    out.* = .empty;

    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return false;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(GuildFields, key)) {
            .id => try readIdentifier(rpc.snowflake_bytes, &out.id, walk),
            .name => try readString(rpc.Guild.name_bytes, &out.name, walk),
            .icon_url => try readString(rpc.Guild.url_bytes, &out.icon_url, walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
    return true;
}

fn readChannelList(out: *rpc.ChannelList, walk: *Walk) Error!void {
    out.* = .empty;

    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(Channels, key)) {
            .channels => try readSummaries(out, walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

fn readSummaries(out: *rpc.ChannelList, walk: *Walk) Error!void {
    out.channels = @splat(.{});
    out.count = try gatherArray(rpc.Channel.Summary, &out.channels, walk, readSummary);
}

/// A summary shares its members with a whole channel, and reads the three it keeps.
fn readSummary(out: *rpc.Channel.Summary, walk: *Walk) Error!bool {
    out.* = .{};

    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return false;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(ChannelFields, key)) {
            .id => try readIdentifier(rpc.snowflake_bytes, &out.id, walk),
            .name => try readString(rpc.Channel.name_bytes, &out.name, walk),
            .type => out.kind = @fromBackingInt(@intCast(try readInteger(walk))),
            else => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
    return true;
}

fn readChannel(out: *rpc.Channel, walk: *Walk) Error!void {
    out.* = .empty;

    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);
    out.found = true;

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(ChannelFields, key)) {
            .id => try readIdentifier(rpc.snowflake_bytes, &out.id, walk),
            .guild_id => try readIdentifier(rpc.snowflake_bytes, &out.guild_id, walk),
            .name => try readString(rpc.Channel.name_bytes, &out.name, walk),
            .type => out.kind = @fromBackingInt(@intCast(try readInteger(walk))),
            .topic => try readString(rpc.Channel.topic_bytes, &out.topic, walk),
            .bitrate => out.bitrate = try readInteger(walk),
            .user_limit => out.user_limit = try readInteger(walk),
            .position => out.position = try readInteger(walk),
            .voice_states => try readVoiceStates(out, walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

fn readVoiceStates(out: *rpc.Channel, walk: *Walk) Error!void {
    out.voice_states = @splat(.empty);
    out.voice_state_count = try gatherArray(
        rpc.VoiceState,
        &out.voice_states,
        walk,
        readVoiceState,
    );
}

fn readVoiceState(out: *rpc.VoiceState, walk: *Walk) Error!bool {
    out.* = .empty;

    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return false;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(VoiceStateFields, key)) {
            .voice_state => try readVoiceFlags(out, walk),
            .user => _ = try readUser(&out.user, walk),
            .nick => try readString(rpc.VoiceState.nick_bytes, &out.nick, walk),
            .volume => out.volume = volumeLevel(try readNumber(walk)),
            .mute => out.locally_muted = try readBool(walk),
            .pan => {
                var left: ?f32 = null;
                var right: ?f32 = null;
                try readPan(&left, &right, walk);
                out.pan_left = left orelse 0;
                out.pan_right = right orelse 0;
            },
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
    return true;
}

fn readVoiceFlags(out: *rpc.VoiceState, walk: *Walk) Error!void {
    const depth = walk.stackHeight();
    if (!try openObject(walk)) {
        assert(walk.stackHeight() == depth);
        return;
    }
    assert(walk.stackHeight() == depth + 1);

    var members: Members = .{ .walk = walk };
    while (try members.next()) |key| {
        switch (match(VoiceFlags, key)) {
            .mute => out.mute = try readBool(walk),
            .deaf => out.deaf = try readBool(walk),
            .self_mute => out.self_mute = try readBool(walk),
            .self_deaf => out.self_deaf = try readBool(walk),
            .suppress => out.suppress = try readBool(walk),
            .other => try walk.skip(),
        }
    }

    assert(walk.stackHeight() == depth);
}

/// Walks an array, reading each element into `items` and passing over what Discord offers past
/// the end of it. Answers how many were kept.
fn gatherArray(
    comptime Item: type,
    items: []Item,
    walk: *Walk,
    comptime readItem: fn (*Item, *Walk) Error!bool,
) Error!u32 {
    const depth = walk.stackHeight();
    if (!try openArray(walk)) {
        assert(walk.stackHeight() == depth);
        return 0;
    }
    assert(walk.stackHeight() == depth + 1);

    var kept: u32 = 0;
    var seen: u32 = 0;
    while (seen < max_members) : (seen += 1) {
        if ((try walk.peek()) == .array_end) break;

        if (kept == items.len) {
            try walk.skip();
            continue;
        }
        if (try readItem(&items[kept], walk)) kept += 1;
    }
    if (seen == max_members) return error.BadPayload;

    _ = try walk.next();
    assert(kept <= items.len);
    assert(walk.stackHeight() == depth);
    return kept;
}

fn openArray(walk: *Walk) Error!bool {
    const depth = walk.stackHeight();

    if (!try take(walk, .array_begin)) {
        assert(walk.stackHeight() <= depth);
        return false;
    }

    assert(walk.stackHeight() == depth + 1);
    return true;
}

fn openObject(walk: *Walk) Error!bool {
    const depth = walk.stackHeight();

    if (!try take(walk, .object_begin)) {
        assert(walk.stackHeight() <= depth);
        return false;
    }

    assert(walk.stackHeight() == depth + 1);
    return true;
}

/// A nonce travels as the string this client wrote; reading it back is how a reply finds the
/// request that made it.
fn readNonce(result: *Frame, walk: *Walk) Error!void {
    const nonce_digits = rpc.nonce_digits;
    const depth = walk.stackHeight();

    var digits: text.Buffer(nonce_digits) = .empty;
    switch (try walk.next()) {
        .string => {
            result.has_nonce = true;
            _ = try gatherString(nonce_digits, &digits, walk);
            trimPartialCodepoint(nonce_digits, &digits);
        },

        // A nonce Discord echoes as a number marks the reply just as a string one does,
        // though only the digits this client wrote parse back to the request.
        .number => result.has_nonce = true,

        .object_begin, .array_begin => try walk.skipUntil(depth),
        else => {},
    }

    assert(walk.stackHeight() <= depth);
    result.nonce = std.fmt.parseInt(u32, digits.slice(), 10) catch 0;
}

/// Reads a string into `out`, truncating a value past its capacity.
fn readString(comptime capacity: u32, out: *text.Buffer(capacity), walk: *Walk) Error!void {
    out.clear();
    assert(out.len == 0);

    if (!try take(walk, .string)) return;

    _ = try gatherString(capacity, out, walk);
    trimPartialCodepoint(capacity, out);

    assert(out.len <= capacity);

    // The scanner holds the payload's own bytes to UTF-8 and an escape resolves to a codepoint,
    // so this is the second, independent path the text is held on.
    assert(scan.validUtf8(out.slice()));
}

/// Reads a value the client hands back to the peer: kept whole, or `error.BadPayload`.
fn readIdentifier(comptime capacity: u32, out: *text.Buffer(capacity), walk: *Walk) Error!void {
    out.clear();
    if (!try take(walk, .string)) return;

    const seen = try gatherString(capacity, out, walk);
    if (seen > capacity) return error.BadPayload;

    assert(out.len == seen);
}

/// Gathers the string the walk has just taken, returning its length before any truncation.
fn gatherString(comptime capacity: u32, out: *text.Buffer(capacity), walk: *Walk) Error!u32 {
    comptime assert(capacity > 0);
    assert(out.len == 0);

    const raw = walk.value();
    if (raw.len > max_value_bytes) return error.BadPayload;

    // Text the payload spells plainly is copied as it stands; only an escape is resolved.
    if (!walk.escaped()) {
        out.append(raw);
        assert(out.len <= capacity);
        return @intCast(raw.len);
    }

    const length = try Scanner.unescape(&out.bytes, raw);
    out.len = @intCast(@min(length, capacity));

    assert(out.len <= capacity);
    return @intCast(length);
}

/// Drops a codepoint the capacity cut in half, so what is kept is whole UTF-8.
fn trimPartialCodepoint(comptime capacity: u32, out: *text.Buffer(capacity)) void {
    assert(out.len <= capacity);

    const bytes = out.slice();

    // A sequence spans at most four bytes, so the lead of the last one is within three.
    var back: u32 = 0;
    while (back < 4 and back < bytes.len) : (back += 1) {
        const lead = bytes.len - 1 - back;
        const length = std.unicode.utf8ByteSequenceLength(bytes[lead]) catch continue;
        if (lead + length > bytes.len) out.len = @intCast(lead);
        return;
    }
}

fn readInteger(walk: *Walk) Error!i32 {
    if (!try take(walk, .number)) return 0;

    // Zero is the code for success, so a number too wide for the field is refused.
    return std.fmt.parseInt(i32, walk.value(), 10) catch error.BadPayload;
}

/// Reads a level or a threshold. A value the field cannot hold is `error.BadPayload`, which
/// keeps a nonsensical setting from reaching a caller as a rounded one.
fn readNumber(walk: *Walk) Error!f32 {
    if (!try take(walk, .number)) return 0;

    return std.fmt.parseFloat(f32, walk.value()) catch error.BadPayload;
}

fn readBool(walk: *Walk) Error!bool {
    const depth = walk.stackHeight();

    switch (try walk.next()) {
        .true => return true,
        .false => return false,

        // Anything else stands for false, and a container is walked out from inside it.
        .object_begin, .array_begin => try walk.skipUntil(depth),
        else => {},
    }

    assert(walk.stackHeight() <= depth);
    return false;
}

/// Takes the next value, answering whether it was of `kind`. A value of another kind is passed
/// over, so the walk stands after it either way and what it carried is `walk.value()`.
///
/// Taking the token is what classifies it, so a caller that dispatches on the kind reads the
/// payload once instead of once to look and once to take.
fn take(walk: *Walk, kind: Scanner.Kind) Error!bool {
    const depth = walk.stackHeight();

    const token = try walk.next();
    if (token == kind) return true;

    // A container is already open, so the rest of it is walked out from inside.
    switch (token) {
        .object_begin, .array_begin => try walk.skipUntil(depth),
        else => {},
    }

    assert(walk.stackHeight() <= depth);
    return false;
}

fn expectObjectBegin(walk: *Walk) Error!void {
    const depth = walk.stackHeight();

    const token = try walk.next();
    if (token != .object_begin) return error.BadPayload;

    assert(walk.stackHeight() == depth + 1);
}

fn complete(payload: []const u8) Error!Frame {
    return frame(payload);
}

test match {
    try std.testing.expectEqual(TopLevel.cmd, match(TopLevel, "cmd"));
    try std.testing.expectEqual(TopLevel.message, match(TopLevel, "message"));
    try std.testing.expectEqual(Account.discriminator, match(Account, "discriminator"));

    try std.testing.expectEqual(TopLevel.other, match(TopLevel, "unknown"));
    try std.testing.expectEqual(TopLevel.other, match(TopLevel, "cmdx"));
    try std.testing.expectEqual(TopLevel.other, match(TopLevel, "cm"));
    try std.testing.expectEqual(TopLevel.other, match(TopLevel, ""));

    try std.testing.expectEqual(TopLevel.other, match(TopLevel, "a_very_long_member_name"));

    var runtime_key: [3]u8 = .{ 'c', 'm', 'd' };
    try std.testing.expectEqual(TopLevel.cmd, match(TopLevel, &runtime_key));
}

test "a READY dispatch yields the connected user" {
    const payload =
        \\{"cmd":"DISPATCH","evt":"READY","data":{"v":1,"config":{"api_endpoint":"//discord.com/api"},"user":{"id":"222222222222222222","username":"example","discriminator":"4242","avatar":"a_0f0","bot":false}}}
    ;

    const parsed = try complete(payload);
    try std.testing.expectEqualStrings("DISPATCH", parsed.command.slice());
    try std.testing.expectEqualStrings("READY", parsed.event.slice());
    try std.testing.expect(parsed.has_user);
    try std.testing.expectEqualStrings("222222222222222222", parsed.user.id.slice());
    try std.testing.expectEqualStrings("example", parsed.user.username.slice());
    try std.testing.expectEqualStrings("4242", parsed.user.discriminator.slice());
    try std.testing.expectEqualStrings("a_0f0", parsed.user.avatar.slice());
    try std.testing.expect(!parsed.has_nonce);
}

test "an activity join yields its secret" {
    const payload =
        \\{"cmd":"DISPATCH","data":{"secret":"abcdef01"},"evt":"ACTIVITY_JOIN"}
    ;

    const parsed = try complete(payload);
    try std.testing.expectEqualStrings("ACTIVITY_JOIN", parsed.event.slice());
    try std.testing.expectEqualStrings("abcdef01", parsed.secret.slice());
    try std.testing.expect(!parsed.has_user);
}

test "a nonce marks a response, and an error carries its code" {
    const payload =
        \\{"nonce":"42","evt":"ERROR","data":{"code":4000,"message":"Invalid activity"}}
    ;

    const parsed = try complete(payload);
    try std.testing.expect(parsed.has_nonce);
    try std.testing.expectEqualStrings("ERROR", parsed.event.slice());
    try std.testing.expectEqual(@as(i32, 4000), parsed.code);
    try std.testing.expectEqualStrings("Invalid activity", parsed.message.slice());
}

test "a close frame carries its code and message at the top level" {
    const payload =
        \\{"code":1000,"message":"closing"}
    ;

    const parsed = try complete(payload);
    try std.testing.expectEqual(@as(i32, 1000), parsed.code);
    try std.testing.expectEqualStrings("closing", parsed.message.slice());
}

test "an escaped string is reassembled from its pieces" {
    const payload =
        \\{"code":1,"message":"line\nbreak \u0041nd \"quotes\""}
    ;

    const parsed = try complete(payload);
    try std.testing.expectEqualStrings("line\nbreak And \"quotes\"", parsed.message.slice());
}

test "a member of the wrong kind reads as absent" {
    const payload =
        \\{"cmd":{"nested":true},"evt":["a"],"code":"not a number","data":42}
    ;

    const parsed = try complete(payload);
    try std.testing.expectEqualStrings("", parsed.command.slice());
    try std.testing.expectEqualStrings("", parsed.event.slice());
    try std.testing.expectEqual(@as(i32, 0), parsed.code);
    try std.testing.expect(!parsed.has_user);
}

/// Nests `depth` arrays under `data`, which is a member the walk descends into.
fn nested(payload: []u8, depth: u32) []const u8 {
    var writer: std.Io.Writer = .fixed(payload);
    writer.writeAll("{\"data\":") catch unreachable;
    for (0..depth) |_| writer.writeAll("[") catch unreachable;
    for (0..depth) |_| writer.writeAll("]") catch unreachable;
    writer.writeAll("}") catch unreachable;
    return writer.buffered();
}

// The depth a walk carries is a number now, so both sides of it are pinned exactly.
test "nesting is carried to the depth the scanner holds, and no further" {
    var payload: [8 * 1024]u8 = undefined;

    // The frame's own object is the first of them.
    _ = try complete(nested(&payload, Scanner.max_depth - 1));

    try std.testing.expectError(
        error.BadPayload,
        complete(nested(&payload, Scanner.max_depth)),
    );
}

test "a frame nested as deeply as real traffic goes still parses" {

    // Deeper than any frame Discord sends, inside a member that is skipped whole.
    const payload =
        \\{"evt":"ACTIVITY_JOIN","extra":{"a":{"b":{"c":{"d":[[[["deep"]]]]}}}},"data":{"secret":"ok"}}
    ;
    const parsed = try complete(payload);
    try std.testing.expectEqualStrings("ACTIVITY_JOIN", parsed.event.slice());
    try std.testing.expectEqualStrings("ok", parsed.secret.slice());
}

test "a member that holds an empty collection is passed over" {
    for ([_][]const u8{
        \\{"data":[]}
        ,
        \\{"data":{}}
        ,
        \\{"evt":"ACTIVITY_JOIN","data":[],"pad":[]}
        ,
        \\{"data":{"user":[]},"evt":"ACTIVITY_JOIN_REQUEST"}
        ,
        \\{"data":{"user":{}},"evt":"ACTIVITY_JOIN_REQUEST"}
        ,
    }) |payload| {
        _ = try complete(payload);
    }

    const parsed = try complete(
        \\{"evt":"ACTIVITY_JOIN","pad":[],"data":{"empty":[],"secret":"ok"}}
    );
    try std.testing.expectEqualStrings("ok", parsed.secret.slice());
}

test "malformed input is refused" {
    try std.testing.expectError(error.BadPayload, complete("{\"cmd\":"));
    try std.testing.expectError(error.BadPayload, complete("not json"));
    try std.testing.expectError(error.BadPayload, complete("[1,2,3]"));
    try std.testing.expectError(error.BadPayload, complete(""));
}

test "a frame at the protocol's size limit parses" {
    var payload: [32 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&payload);
    try writer.writeAll("{\"evt\":\"ACTIVITY_JOIN\",\"data\":{\"secret\":\"deadbeef\"");
    var member_index: u32 = 0;
    while (member_index < 1000) : (member_index += 1) {
        try writer.print(",\"field{d}\":\"value{d}\"", .{ member_index, member_index });
    }
    try writer.writeAll("}}");

    const parsed = try complete(writer.buffered());
    try std.testing.expect(writer.end > 16 * 1024);
    try std.testing.expectEqualStrings("ACTIVITY_JOIN", parsed.event.slice());
    try std.testing.expectEqualStrings("deadbeef", parsed.secret.slice());
}

test "a value of the wrong kind is consumed whole, so the walk stays at its own level" {

    // A nested object's members must not be read as the top level's.
    const forged = try complete(
        \\{"cmd":{"nonce":1,"evt":"ERROR","code":4000,"message":"boom"}}
    );
    try std.testing.expect(!forged.has_nonce);
    try std.testing.expectEqualStrings("", forged.event.slice());
    try std.testing.expectEqual(@as(i32, 0), forged.code);
    try std.testing.expectEqualStrings("", forged.message.slice());

    // A collection in a string's place must not swallow the members after it.
    const suppressed = try complete(
        \\{"cmd":{},"evt":"READY","data":{"user":{"id":"1","username":"u"}}}
    );
    try std.testing.expectEqualStrings("READY", suppressed.event.slice());
    try std.testing.expect(suppressed.has_user);

    const numeric = try complete(
        \\{"code":[1,2,3],"message":"closing"}
    );
    try std.testing.expectEqual(@as(i32, 0), numeric.code);
    try std.testing.expectEqualStrings("closing", numeric.message.slice());
}

test "a repeated object starts from empty, so its fields cannot be merged" {
    const merged = try complete(
        \\{"evt":"ACTIVITY_JOIN_REQUEST","data":{"user":{"id":"111","username":"trusted"}},"data":{"user":{"id":"999"}}}
    );
    try std.testing.expectEqualStrings("999", merged.user.id.slice());
    try std.testing.expectEqualStrings("", merged.user.username.slice());
}

test "the walk ends where the bytes end" {
    try std.testing.expectError(error.BadPayload, complete(
        \\{"evt":"ACTIVITY_JOIN","data":{"secret":"a"}}{"evt":"ERROR","code":4000}
    ));
    try std.testing.expectError(error.BadPayload, complete("{\"code\":1} junk"));

    // Trailing whitespace is still one document.
    _ = try complete("{\"code\":1}  \n");
}

test "a field belongs to one object, and the level precedence does not depend on order" {

    // The last `data` answers for the whole member; nothing survives from the first.
    const blended = try complete(
        \\{"data":{"secret":"legit"},"data":{"code":4000,"message":"boom"}}
    );
    try std.testing.expectEqualStrings("", blended.secret.slice());
    try std.testing.expectEqual(@as(i32, 4000), blended.code);

    // `data` wins over the top level whichever arrives first.
    const before = try complete("{\"data\":{\"code\":4000},\"code\":10}");
    const after = try complete("{\"code\":10,\"data\":{\"code\":4000}}");
    try std.testing.expectEqual(@as(i32, 4000), before.code);
    try std.testing.expectEqual(after.code, before.code);

    // A wrong-kind repeat still answers for the member, so no earlier user stands.
    const stale = try complete(
        \\{"data":{"user":{"id":"111","username":"trusted"},"user":[]}}
    );
    try std.testing.expect(!stale.has_user);
    try std.testing.expectEqualStrings("", stale.user.id.slice());
}

test "a code that will not fit is refused, because zero already means success" {
    try std.testing.expectError(error.BadPayload, complete("{\"code\":2147483648}"));
    try std.testing.expectError(error.BadPayload, complete("{\"code\":-2147483649}"));
    try std.testing.expectError(error.BadPayload, complete("{\"code\":4000.0}"));
    try std.testing.expectEqual(@as(i32, 1000), (try complete("{\"code\":1000}")).code);
}

// `data.code` carries a number on a refusal and the authorization string on a consent, so
// the two land in separate fields and neither reads the other's value.
test "a code lands where its kind belongs" {
    const consented = try complete(
        \\{"cmd":"AUTHORIZE","nonce":"4","data":{"code":"ZDI0YmE4YzFmMg"}}
    );
    try std.testing.expectEqualStrings("ZDI0YmE4YzFmMg", consented.authorization.slice());
    try std.testing.expectEqual(@as(i32, 0), consented.code);

    const refused = try complete(
        \\{"cmd":"AUTHORIZE","nonce":"4","evt":"ERROR","data":{"code":4006,"message":"nope"}}
    );
    try std.testing.expectEqual(@as(i32, 4006), refused.code);
    try std.testing.expectEqual(@as(usize, 0), refused.authorization.len);

    // A repeated `data` answers for all of it, so the later one clears what the first left.
    const repeated = try complete(
        \\{"data":{"code":"first"},"data":{"code":4000}}
    );
    try std.testing.expectEqual(@as(i32, 4000), repeated.code);
    try std.testing.expectEqual(@as(usize, 0), repeated.authorization.len);
}

test "a nonce marks a response only when it is one" {
    try std.testing.expect(!(try complete("{\"nonce\":null}")).has_nonce);
    try std.testing.expect(!(try complete("{\"nonce\":{}}")).has_nonce);
    try std.testing.expect(!(try complete("{\"nonce\":[]}")).has_nonce);
    try std.testing.expect((try complete("{\"nonce\":\"7\"}")).has_nonce);
    try std.testing.expect((try complete("{\"nonce\":7}")).has_nonce);
}

test "a value cut at its capacity stays valid UTF-8" {
    const gpa = std.testing.allocator;

    // One byte short of the capacity, then a two-byte codepoint straddling the end.
    const capacity = User.capacityOf("username");
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try payload.appendSlice(gpa, "{\"data\":{\"user\":{\"username\":\"");
    try payload.appendNTimes(gpa, '1', capacity - 1);
    try payload.appendSlice(gpa, "\\u00e9\"}}}");

    const parsed = try complete(payload.items);
    try std.testing.expect(std.unicode.utf8ValidateSlice(parsed.user.username.slice()));
    try std.testing.expectEqual(@as(usize, capacity - 1), parsed.user.username.len);
}

test "a value the client echoes back is never silently shortened" {
    const long_id = "1234567890123456789012345678901234567890";
    try std.testing.expect(long_id.len > User.capacityOf("id"));
    try std.testing.expectError(error.BadPayload, complete(
        "{\"data\":{\"user\":{\"id\":\"" ++ long_id ++ "\"}}}",
    ));

    // A snowflake is twenty digits at most, so nothing Discord sends reaches the capacity.
    const parsed = try complete("{\"data\":{\"user\":{\"id\":\"222222222222222222\"}}}");
    try std.testing.expectEqualStrings("222222222222222222", parsed.user.id.slice());
}

test "a voice configuration is read from the payload the frame came from" {
    var settings: rpc.VoiceSettings = .empty;

    const payload =
        \\{"cmd":"GET_VOICE_SETTINGS","evt":null,"nonce":"1","data":{
        \\"input":{"device_id":"default","volume":51.5,"available_devices":[
        \\{"id":"default","name":"Default"},{"id":"mic-1","name":"Microphone"}]},
        \\"output":{"device_id":"speakers","volume":140.25,"available_devices":[]},
        \\"mode":{"type":"PUSH_TO_TALK","auto_threshold":false,"threshold":-52.5,"delay":21.5,
        \\"shortcut":[{"type":0,"code":12,"name":"f12"},{"type":2,"code":16,"name":"shift"}]},
        \\"automatic_gain_control":true,"echo_cancellation":false,"noise_suppression":true,
        \\"qos":true,"silence_warning":false,"deaf":false,"mute":true}}
    ;
    try into(.{ .voice_settings = &settings }, payload);

    try std.testing.expectEqualStrings("default", settings.input.device_id.slice());
    try std.testing.expectEqual(@as(f32, 51.5), settings.input.volume);
    try std.testing.expectEqual(@as(u32, 2), settings.input.device_count);
    try std.testing.expectEqualStrings("Microphone", settings.input.devices[1].name.slice());

    try std.testing.expectEqualStrings("speakers", settings.output.device_id.slice());
    try std.testing.expectEqual(@as(u32, 0), settings.output.device_count);

    try std.testing.expectEqual(rpc.VoiceSettings.Mode.Kind.push_to_talk, settings.mode.kind);
    try std.testing.expectEqual(@as(f32, -52.5), settings.mode.threshold);
    try std.testing.expectEqual(@as(u32, 2), settings.mode.shortcut_count);
    try std.testing.expectEqualStrings("shift", settings.mode.shortcut[1].name.slice());
    try std.testing.expectEqual(@as(i32, 2), settings.mode.shortcut[1].kind);

    try std.testing.expect(settings.automatic_gain_control);
    try std.testing.expect(settings.mute);
    try std.testing.expect(!settings.deaf);
}

test "a device list longer than the capacity keeps what fits" {
    var settings: rpc.VoiceSettings = .empty;

    const capacity = rpc.VoiceSettings.device_capacity;
    try std.testing.expectEqual(8, capacity);

    // Ten offered where eight fit, so the ones past the capacity are visibly dropped.
    const payload =
        \\{"data":{"input":{"available_devices":[
        \\{"id":"d","name":"n"},{"id":"d","name":"n"},{"id":"d","name":"n"},
        \\{"id":"d","name":"n"},{"id":"d","name":"n"},{"id":"d","name":"n"},
        \\{"id":"d","name":"n"},{"id":"d","name":"n"},{"id":"d","name":"n"},
        \\{"id":"last","name":"n"}]}}}
    ;

    try into(.{ .voice_settings = &settings }, payload);
    try std.testing.expectEqual(capacity, settings.input.device_count);
    try std.testing.expectEqualStrings("d", settings.input.devices[capacity - 1].id.slice());
}

test "a user's mix reports only what Discord answered with" {
    var mix: rpc.UserVoiceSettings = .empty;

    try into(
        .{ .user_voice_settings = &mix },
        "{\"data\":{\"user_id\":\"2\",\"pan\":{\"left\":0.25,\"right\":1},\"volume\":150}}",
    );
    try std.testing.expectEqual(@as(f32, 0.25), mix.pan_left.?);
    try std.testing.expectEqual(@as(f32, 1), mix.pan_right.?);
    try std.testing.expectEqual(@as(u32, 150), mix.volume.?);
    try std.testing.expectEqual(null, mix.mute);

    // A level past the ceiling is held to it, so the field cannot be handed a
    // value it has no room for.
    try into(.{ .user_voice_settings = &mix }, "{\"data\":{\"volume\":1e30}}");
    try std.testing.expectEqual(rpc.UserVoiceSettings.volume_max, mix.volume.?);
    try std.testing.expectEqual(null, mix.pan_left);
}

test "a guild list keeps what fits and counts it" {
    var listed: rpc.GuildList = .empty;

    try into(.{ .guilds = &listed },
        \\{"cmd":"GET_GUILDS","nonce":"1","data":{"guilds":[
        \\{"id":"333333333333333333","name":"one","icon_url":"https://example.invalid/a.png"},
        \\{"id":"444444444444444444","name":"two"}]}}
    );

    try std.testing.expectEqual(@as(u32, 2), listed.count);
    try std.testing.expectEqualStrings("333333333333333333", listed.guilds[0].id.slice());
    try std.testing.expectEqualStrings("one", listed.guilds[0].name.slice());
    try std.testing.expectEqualStrings(
        "https://example.invalid/a.png",
        listed.guilds[0].icon_url.slice(),
    );
    try std.testing.expectEqualStrings("two", listed.guilds[1].name.slice());
    try std.testing.expectEqual(@as(u8, 0), listed.guilds[1].icon_url.len);

    // An empty list is a user in no guilds, which reads back as none.
    try into(.{ .guilds = &listed }, "{\"data\":{\"guilds\":[]}}");
    try std.testing.expectEqual(@as(u32, 0), listed.count);
}

test "a channel reports who is in it" {
    var found: rpc.Channel = .empty;

    try into(.{ .channel = &found },
        \\{"cmd":"GET_CHANNEL","nonce":"1","data":{"id":"444444444444444444",
        \\"guild_id":"333333333333333333","name":"general","type":2,"topic":"talk",
        \\"bitrate":64000,"user_limit":5,"position":3,"voice_states":[
        \\{"nick":"someone","mute":true,"volume":120,"pan":{"left":0.25,"right":0.75},
        \\"voice_state":{"mute":false,"deaf":false,"self_mute":true,"self_deaf":false,
        \\"suppress":false},"user":{"id":"222222222222222222","username":"example"}}]}}
    );

    try std.testing.expect(found.found);
    try std.testing.expectEqualStrings("444444444444444444", found.id.slice());
    try std.testing.expectEqualStrings("333333333333333333", found.guild_id.slice());
    try std.testing.expectEqualStrings("general", found.name.slice());
    try std.testing.expectEqual(rpc.Channel.Kind.guild_voice, found.kind);
    try std.testing.expectEqualStrings("talk", found.topic.slice());
    try std.testing.expectEqual(@as(i32, 64000), found.bitrate);
    try std.testing.expectEqual(@as(i32, 5), found.user_limit);
    try std.testing.expectEqual(@as(i32, 3), found.position);

    try std.testing.expectEqual(@as(u32, 1), found.voice_state_count);
    const state = found.voice_states[0];
    try std.testing.expectEqualStrings("someone", state.nick.slice());
    try std.testing.expectEqualStrings("example", state.user.username.slice());
    try std.testing.expect(state.locally_muted);
    try std.testing.expect(state.self_mute);
    try std.testing.expect(!state.mute);
    try std.testing.expectEqual(@as(u32, 120), state.volume);
    try std.testing.expectEqual(@as(f32, 0.25), state.pan_left);
    try std.testing.expectEqual(@as(f32, 0.75), state.pan_right);
}

test "leaving a channel is answered with none" {
    var found: rpc.Channel = .empty;

    try into(.{ .channel = &found }, "{\"cmd\":\"SELECT_VOICE_CHANNEL\",\"data\":null}");
    try std.testing.expect(!found.found);
    try std.testing.expectEqual(@as(u8, 0), found.id.len);
}

test "a channel list reads the three members that name a channel" {
    var listed: rpc.ChannelList = .empty;

    try into(.{ .channels = &listed },
        \\{"data":{"channels":[{"id":"444444444444444444","name":"general","type":0,
        \\"topic":"passed over","voice_states":[{"nick":"also passed over"}]},
        \\{"id":"555555555555555555","name":"voice","type":2}]}}
    );

    try std.testing.expectEqual(@as(u32, 2), listed.count);
    try std.testing.expectEqualStrings("general", listed.channels[0].name.slice());
    try std.testing.expectEqual(rpc.Channel.Kind.guild_text, listed.channels[0].kind);
    try std.testing.expectEqualStrings("555555555555555555", listed.channels[1].id.slice());
    try std.testing.expectEqual(rpc.Channel.Kind.guild_voice, listed.channels[1].kind);
}

// The numbering is Discord's, and it adds kinds, so one this build never heard of survives.
test "a channel kind outside the numbering is carried whole" {
    var found: rpc.Channel = .empty;

    try into(.{ .channel = &found }, "{\"data\":{\"type\":15}}");
    try std.testing.expectEqual(@as(i32, 15), @backingInt(found.kind));
}

test "a subscribed event carries the shape its name says" {
    var payload: rpc.Payload = .none;

    const walkNotice = struct {
        fn call(raised: rpc.Event, sent: []const u8, out: *rpc.Payload) !void {
            try into(.{ .notice = .{ .event = raised, .out = out } }, sent);

            // The event decides the shape, so the two can never disagree.
            try std.testing.expectEqual(raised.shape(), @as(rpc.Payload.Shape, out.*));
        }
    }.call;

    try walkNotice(.message_create,
        \\{"cmd":"DISPATCH","evt":"MESSAGE_CREATE","data":{"channel_id":"444444444444444444",
        \\"message":{"id":"555555555555555555","content":"hello","nick":"someone",
        \\"author":{"id":"222222222222222222","username":"example"}}}}
    , &payload);
    try std.testing.expectEqualStrings("444444444444444444", payload.message.channel_id.slice());
    try std.testing.expectEqualStrings("555555555555555555", payload.message.id.slice());
    try std.testing.expectEqualStrings("hello", payload.message.content.slice());
    try std.testing.expectEqualStrings("someone", payload.message.nick.slice());
    try std.testing.expectEqualStrings("example", payload.message.author.username.slice());

    try walkNotice(.notification_create,
        \\{"data":{"channel_id":"444444444444444444","title":"example","body":"hello",
        \\"icon_url":"https://example.invalid/a.png",
        \\"message":{"author":{"id":"222222222222222222","username":"example"}}}}
    , &payload);
    try std.testing.expectEqualStrings("example", payload.notification.title.slice());
    try std.testing.expectEqualStrings("hello", payload.notification.body.slice());
    try std.testing.expectEqualStrings("example", payload.notification.author.username.slice());

    const speaking = "{\"data\":{\"user_id\":\"222222222222222222\"}}";
    try walkNotice(.speaking_start, speaking, &payload);
    try std.testing.expectEqualStrings("222222222222222222", payload.speaking.user_id.slice());

    // A guild names itself one object down, and a channel at the top level.
    try walkNotice(.guild_status,
        \\{"data":{"guild":{"id":"333333333333333333","name":"a guild"},"online":4}}
    , &payload);
    try std.testing.expectEqualStrings("333333333333333333", payload.guild.id.slice());
    try std.testing.expectEqualStrings("a guild", payload.guild.name.slice());

    try walkNotice(.guild_create,
        \\{"data":{"id":"333333333333333333","name":"a guild"}}
    , &payload);
    try std.testing.expectEqualStrings("a guild", payload.guild.name.slice());

    // An entitlement is wrapped in a member of its own.
    try walkNotice(.entitlement_create,
        \\{"data":{"entitlement":{"id":"666666666666666666","sku_id":"777777777777777777"}}}
    , &payload);
    try std.testing.expectEqualStrings("666666666666666666", payload.entitlement.id.slice());
    try std.testing.expectEqualStrings("777777777777777777", payload.entitlement.sku_id.slice());

    try walkNotice(.voice_connection_status,
        \\{"data":{"state":"CONNECTED","hostname":"example.invalid","average_ping":42,
        \\"last_ping":40,"pings":[42,40]}}
    , &payload);
    try std.testing.expectEqualStrings("CONNECTED", payload.connection.state.slice());
    try std.testing.expectEqualStrings("example.invalid", payload.connection.hostname.slice());
    try std.testing.expectEqual(@as(i32, 42), payload.connection.average_ping);

    // The settings themselves are wider than an event queue carries, so the event
    // says only that they changed.
    try walkNotice(.voice_settings_update, "{\"data\":{\"mute\":true}}", &payload);
}

test "a payload the walk cannot read leaves the shape the event named" {
    var payload: rpc.Payload = .none;

    // A member of the wrong kind is passed over, and the rest of the payload survives it.
    try into(
        .{ .notice = .{ .event = .message_create, .out = &payload } },
        "{\"data\":{\"channel_id\":42,\"message\":{\"content\":\"hello\"}}}",
    );
    try std.testing.expectEqual(@as(u8, 0), payload.message.channel_id.len);
    try std.testing.expectEqualStrings("hello", payload.message.content.slice());

    try std.testing.expectError(error.BadPayload, into(
        .{ .notice = .{ .event = .message_create, .out = &payload } },
        "{\"data\":{",
    ));
}

test "a reply the walk cannot read is refused whole" {
    var settings: rpc.VoiceSettings = .empty;

    try std.testing.expectError(error.BadPayload, into(
        .{ .voice_settings = &settings },
        "{\"data\":{\"input\":{\"volume\":1.2.3}}}",
    ));
    try std.testing.expectError(error.BadPayload, into(
        .{ .voice_settings = &settings },
        "{\"data\":{}} trailing",
    ));

    // A member of the wrong kind is passed over, which keeps one odd field from losing the
    // rest of the reply.
    try into(
        .{ .voice_settings = &settings },
        "{\"data\":{\"mute\":\"yes\",\"deaf\":true,\"mode\":42}}",
    );
    try std.testing.expect(!settings.mute);
    try std.testing.expect(settings.deaf);
}
