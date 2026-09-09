//! Command payloads, written straight into a caller-owned buffer.
//!
//! Each command names the shape it travels in and hands it to `json`, so what is here is what
//! Discord asks for and nothing about how JSON is spelled.
//!
//! An absent field is `null` and is left out; Discord distinguishes that from present but
//! empty. A nonce travels as a JSON string and is echoed back verbatim on the response.

const std = @import("std");
const assert = std.debug.assert;

const json = @import("../json/root.zig");
const Presence = @import("../Presence.zig");
const rpc = @import("root.zig");

pub const Error = json.Error;

/// A presence the caller got wrong: a party larger than its own maximum, text that is not
/// valid UTF-8, or a button whose label or link the protocol will not carry.
pub const PresenceError = Error || error{InvalidPresence};

const nonce_digits = rpc.nonce_digits;

pub const Reply = enum(u8) {
    no = 0,
    yes = 1,
    /// Discord treats an ignored request the same as a refused one.
    ignore = 2,

    fn command(reply: Reply) []const u8 {
        return switch (reply) {
            .yes => "SEND_ACTIVITY_JOIN_INVITE",
            .no, .ignore => "CLOSE_ACTIVITY_JOIN_REQUEST",
        };
    }
};

pub const Subscription = enum {
    subscribe,
    unsubscribe,

    fn command(action: Subscription) []const u8 {
        return switch (action) {
            .subscribe => "SUBSCRIBE",
            .unsubscribe => "UNSUBSCRIBE",
        };
    }
};

pub fn handshake(buffer: []u8, version: u32, application_id: []const u8) Error!u32 {
    assert(application_id.len > 0);

    const Handshake = struct {
        v: u32,
        client_id: []const u8,
    };
    return json.write(buffer, Handshake, .{ .v = version, .client_id = application_id });
}

/// `key` names the guild or channel a scoped event is watched on, and is empty for the events
/// that carry no scope.
pub fn subscription(
    buffer: []u8,
    nonce: u32,
    action: Subscription,
    subscribed: rpc.Event,
    key: []const u8,
) Error!u32 {
    assert(key.len <= rpc.snowflake_bytes);
    if (subscribed.scope() == .global) assert(key.len == 0) else assert(key.len > 0);

    const Arguments = struct { guild_id: ?[]const u8, channel_id: ?[]const u8 };
    const arguments: ?Arguments = switch (subscribed.scope()) {
        .global => null,
        .guild => .{ .guild_id = key, .channel_id = null },
        .channel => .{ .guild_id = null, .channel_id = key },
    };

    const Subscribe = struct {
        nonce: []const u8,
        cmd: []const u8,
        evt: []const u8,
        args: ?Arguments,
    };
    var digits: [nonce_digits]u8 = undefined;
    return json.write(buffer, Subscribe, .{
        .nonce = formatNonce(&digits, nonce),
        .cmd = action.command(),
        .evt = subscribed.name(),
        .args = arguments,
    });
}

/// Asks Discord to put the consent modal in front of the user. Discord answers with a
/// one-time code, which the caller trades for a token away from here: that exchange carries
/// an application secret, which belongs on a server the application owns.
pub fn authorize(
    buffer: []u8,
    nonce: u32,
    application_id: []const u8,
    scopes: []const []const u8,
) Error!u32 {
    assert(application_id.len > 0);
    assert(scopes.len > 0);

    const Authorize = struct {
        nonce: []const u8,
        cmd: []const u8,
        args: struct {
            client_id: []const u8,
            scopes: []const []const u8,
        },
    };
    var digits: [nonce_digits]u8 = undefined;
    return json.write(buffer, Authorize, .{
        .nonce = formatNonce(&digits, nonce),
        .cmd = "AUTHORIZE",
        .args = .{ .client_id = application_id, .scopes = scopes },
    });
}

/// Hands Discord a token the caller already exchanged for. Discord answers with the account
/// it belongs to and the scopes it carries.
pub fn authenticate(buffer: []u8, nonce: u32, access_token: []const u8) Error!u32 {
    assert(access_token.len > 0);

    const Authenticate = struct {
        nonce: []const u8,
        cmd: []const u8,
        args: struct { access_token: []const u8 },
    };
    var digits: [nonce_digits]u8 = undefined;
    return json.write(buffer, Authenticate, .{
        .nonce = formatNonce(&digits, nonce),
        .cmd = "AUTHENTICATE",
        .args = .{ .access_token = access_token },
    });
}

pub fn getVoiceSettings(buffer: []u8, nonce: u32) Error!u32 {
    return plainCommand(buffer, nonce, "GET_VOICE_SETTINGS");
}

/// Discord keeps what an absent field would have named, so each object is written only once
/// something inside it is being changed.
///
/// Assumes `checkVoiceUpdate` has passed on `update`.
pub fn setVoiceSettings(
    buffer: []u8,
    nonce: u32,
    update: *const rpc.VoiceSettings.Update,
) Error!u32 {
    var storage: [rpc.VoiceSettings.shortcut_capacity]Key = undefined;
    const shortcut = shortcutKeys(&storage, update.shortcut);

    const input: ?Channel = if (update.input_device_id == null and update.input_volume == null)
        null
    else
        .{ .device_id = update.input_device_id, .volume = update.input_volume };

    const output: ?Channel = if (update.output_device_id == null and update.output_volume == null)
        null
    else
        .{ .device_id = update.output_device_id, .volume = update.output_volume };

    const mode: ?Mode = if (update.mode == null and update.mode_auto_threshold == null and
        update.mode_threshold == null and update.mode_delay == null and shortcut == null)
        null
    else
        .{
            .type = if (update.mode) |kind| kind.name() else null,
            .auto_threshold = update.mode_auto_threshold,
            .threshold = update.mode_threshold,
            .delay = update.mode_delay,
            .shortcut = shortcut,
        };

    var digits: [nonce_digits]u8 = undefined;
    return json.write(buffer, VoiceUpdate, .{
        .nonce = formatNonce(&digits, nonce),
        .cmd = "SET_VOICE_SETTINGS",
        .args = .{
            .input = input,
            .output = output,
            .mode = mode,
            .automatic_gain_control = update.automatic_gain_control,
            .echo_cancellation = update.echo_cancellation,
            .noise_suppression = update.noise_suppression,
            .qos = update.qos,
            .silence_warning = update.silence_warning,
            .deaf = update.deaf,
            .mute = update.mute,
        },
    });
}

const Key = struct {
    type: i32,
    code: i32,
    name: []const u8,
};

const Channel = struct {
    device_id: ?[]const u8,
    volume: ?f32,
};

const Mode = struct {
    type: ?[]const u8,
    auto_threshold: ?bool,
    threshold: ?f32,
    delay: ?f32,
    shortcut: ?[]const Key,
};

const VoiceUpdate = struct {
    nonce: []const u8,
    cmd: []const u8,
    args: struct {
        input: ?Channel,
        output: ?Channel,
        mode: ?Mode,
        automatic_gain_control: ?bool,
        echo_cancellation: ?bool,
        noise_suppression: ?bool,
        qos: ?bool,
        silence_warning: ?bool,
        deaf: ?bool,
        mute: ?bool,
    },
};

/// The inline names travel as slices, so each is taken from the caller's own key and not from
/// a copy this makes of it.
fn shortcutKeys(
    storage: *[rpc.VoiceSettings.shortcut_capacity]Key,
    given: ?[]const rpc.VoiceSettings.Shortcut,
) ?[]const Key {
    const keys = given orelse return null;
    assert(keys.len <= storage.len);

    for (keys, storage[0..keys.len]) |*key, *entry| {
        entry.* = .{ .type = key.kind, .code = key.code, .name = key.name.slice() };
    }
    return storage[0..keys.len];
}

/// A device id is held to what the field carrying it back can hold, so a settings buffer is
/// sized from the capacities alone.
pub fn checkVoiceUpdate(update: *const rpc.VoiceSettings.Update) error{InvalidVoiceSettings}!void {
    if (update.shortcut) |keys| {
        if (keys.len > rpc.VoiceSettings.shortcut_capacity) return error.InvalidVoiceSettings;
    }

    for ([_]?[]const u8{ update.input_device_id, update.output_device_id }) |field| {
        const device_id = field orelse continue;
        if (device_id.len > rpc.VoiceSettings.device_bytes) return error.InvalidVoiceSettings;
        if (!std.unicode.utf8ValidateSlice(device_id)) return error.InvalidVoiceSettings;
    }

    for ([_]?f32{
        update.input_volume,
        update.output_volume,
        update.mode_threshold,
        update.mode_delay,
    }) |field| {
        const value = field orelse continue;
        if (!std.math.isFinite(value)) return error.InvalidVoiceSettings;
    }
}

/// Discord takes a pan as one object, so a caller naming half of one is naming nothing.
pub fn checkUserVoiceSettings(
    settings: *const rpc.UserVoiceSettings,
) error{InvalidVoiceSettings}!void {
    if (settings.volume) |level| {
        if (level > rpc.UserVoiceSettings.volume_max) return error.InvalidVoiceSettings;
    }

    const left = settings.pan_left orelse {
        if (settings.pan_right != null) return error.InvalidVoiceSettings;
        return;
    };
    const right = settings.pan_right orelse return error.InvalidVoiceSettings;

    if (!std.math.isFinite(left)) return error.InvalidVoiceSettings;
    if (!std.math.isFinite(right)) return error.InvalidVoiceSettings;
}

/// Assumes `checkUserVoiceSettings` has passed on `settings`.
pub fn setUserVoiceSettings(
    buffer: []u8,
    nonce: u32,
    user_id: []const u8,
    settings: *const rpc.UserVoiceSettings,
) Error!u32 {
    assert(user_id.len > 0);

    const Pan = struct { left: f32, right: f32 };
    const pan: ?Pan = pan: {
        const left = settings.pan_left orelse {
            assert(settings.pan_right == null);
            break :pan null;
        };
        const right = settings.pan_right.?;
        assert(std.math.isFinite(left));
        assert(std.math.isFinite(right));
        break :pan .{ .left = left, .right = right };
    };

    const Settings = struct {
        nonce: []const u8,
        cmd: []const u8,
        args: struct {
            user_id: []const u8,
            pan: ?Pan,
            volume: ?u32,
            mute: ?bool,
        },
    };
    var digits: [nonce_digits]u8 = undefined;
    return json.write(buffer, Settings, .{
        .nonce = formatNonce(&digits, nonce),
        .cmd = "SET_USER_VOICE_SETTINGS",
        .args = .{
            .user_id = user_id,
            .pan = pan,
            .volume = settings.volume,
            .mute = settings.mute,
        },
    });
}

/// The devices a manufacturer offers, in the order Discord should prefer them.
///
/// Assumes `checkDevices` has passed on `devices`.
pub fn certifiedDevices(
    buffer: []u8,
    nonce: u32,
    devices: []const rpc.CertifiedDevice,
) Error!u32 {
    assert(devices.len <= rpc.CertifiedDevice.capacity);

    var entries: [rpc.CertifiedDevice.capacity]Certified = undefined;
    for (devices, entries[0..devices.len]) |device, *entry| {
        entry.* = .{
            .type = device.kind.name(),
            .id = device.id,
            .vendor = .{ .name = device.vendor_name, .url = device.vendor_url },
            .model = .{ .name = device.model_name, .url = device.model_url },
            .related = device.related,
            .echo_cancellation = device.echo_cancellation,
            .noise_suppression = device.noise_suppression,
            .automatic_gain_control = device.automatic_gain_control,
            .hardware_mute = device.hardware_mute,
        };
    }

    const Devices = struct {
        nonce: []const u8,
        cmd: []const u8,
        args: struct { devices: []const Certified },
    };
    var digits: [nonce_digits]u8 = undefined;
    return json.write(buffer, Devices, .{
        .nonce = formatNonce(&digits, nonce),
        .cmd = "SET_CERTIFIED_DEVICES",
        .args = .{ .devices = entries[0..devices.len] },
    });
}

const Certified = struct {
    type: []const u8,
    id: []const u8,
    vendor: struct { name: []const u8, url: []const u8 },
    model: struct { name: []const u8, url: []const u8 },
    related: []const []const u8,
    echo_cancellation: ?bool,
    noise_suppression: ?bool,
    automatic_gain_control: ?bool,
    hardware_mute: ?bool,
};

pub fn checkDevices(devices: []const rpc.CertifiedDevice) error{InvalidDevice}!void {
    if (devices.len > rpc.CertifiedDevice.capacity) return error.InvalidDevice;

    for (devices) |device| {
        if (device.related.len > rpc.CertifiedDevice.related_capacity) return error.InvalidDevice;

        for ([_][]const u8{
            device.id,
            device.vendor_name,
            device.vendor_url,
            device.model_name,
            device.model_url,
        }) |field| try checkDeviceText(field);

        for (device.related) |related| try checkDeviceText(related);
    }
}

/// Held to the characters that escape to themselves, so a whole list's written size is the
/// sum of its lengths and the buffer it goes into can be sized from that.
fn checkDeviceText(value: []const u8) error{InvalidDevice}!void {
    if (value.len == 0) return error.InvalidDevice;
    if (value.len > rpc.CertifiedDevice.text_bytes) return error.InvalidDevice;
    if (!json.scan.plain(value)) return error.InvalidDevice;
}

/// A guild id or a channel id that Discord will not read back.
pub const IdError = Error || error{InvalidId};

pub fn checkId(id: []const u8) error{InvalidId}!void {
    if (id.len == 0) return error.InvalidId;
    if (id.len > rpc.snowflake_bytes) return error.InvalidId;

    for (id) |character| {
        if (character < '0') return error.InvalidId;
        if (character > '9') return error.InvalidId;
    }
}

pub fn getGuilds(buffer: []u8, nonce: u32) Error!u32 {
    return plainCommand(buffer, nonce, "GET_GUILDS");
}

pub fn getSelectedVoiceChannel(buffer: []u8, nonce: u32) Error!u32 {
    return plainCommand(buffer, nonce, "GET_SELECTED_VOICE_CHANNEL");
}

/// A command whose whole request is its own name.
fn plainCommand(buffer: []u8, nonce: u32, name: []const u8) Error!u32 {
    assert(name.len > 0);

    const Plain = struct {
        nonce: []const u8,
        cmd: []const u8,
    };
    var digits: [nonce_digits]u8 = undefined;
    return json.write(buffer, Plain, .{
        .nonce = formatNonce(&digits, nonce),
        .cmd = name,
    });
}

/// Assumes `checkId` has passed on `guild_id`.
pub fn getGuild(buffer: []u8, nonce: u32, guild_id: []const u8, timeout_seconds: i32) Error!u32 {
    assert(guild_id.len > 0);

    const Query = struct {
        nonce: []const u8,
        cmd: []const u8,
        args: struct { guild_id: []const u8, timeout: ?i32 },
    };
    var digits: [nonce_digits]u8 = undefined;
    return json.write(buffer, Query, .{
        .nonce = formatNonce(&digits, nonce),
        .cmd = "GET_GUILD",
        .args = .{
            .guild_id = guild_id,
            .timeout = if (timeout_seconds > 0) timeout_seconds else null,
        },
    });
}

/// Assumes `checkId` has passed on `guild_id`.
pub fn getChannels(buffer: []u8, nonce: u32, guild_id: []const u8) Error!u32 {
    assert(guild_id.len > 0);

    const Query = struct {
        nonce: []const u8,
        cmd: []const u8,
        args: struct { guild_id: []const u8 },
    };
    var digits: [nonce_digits]u8 = undefined;
    return json.write(buffer, Query, .{
        .nonce = formatNonce(&digits, nonce),
        .cmd = "GET_CHANNELS",
        .args = .{ .guild_id = guild_id },
    });
}

/// Assumes `checkId` has passed on `channel_id`.
pub fn getChannel(buffer: []u8, nonce: u32, channel_id: []const u8) Error!u32 {
    assert(channel_id.len > 0);

    const Query = struct {
        nonce: []const u8,
        cmd: []const u8,
        args: struct { channel_id: []const u8 },
    };
    var digits: [nonce_digits]u8 = undefined;
    return json.write(buffer, Query, .{
        .nonce = formatNonce(&digits, nonce),
        .cmd = "GET_CHANNEL",
        .args = .{ .channel_id = channel_id },
    });
}

/// What `selectVoiceChannel` does beyond naming the channel.
pub const VoiceSelect = struct {
    /// How long Discord waits before it gives up joining, in seconds. Zero leaves
    /// it to Discord's own default.
    timeout_seconds: i32 = 0,
    /// Takes the user out of the channel they are in, even one they are already speaking in.
    force: bool = false,
    /// Brings the joined channel up in the Discord window.
    navigate: bool = false,
};

/// A null `channel_id` leaves the channel the user is in.
///
/// Assumes `checkId` has passed on `channel_id` when one is given.
pub fn selectVoiceChannel(
    buffer: []u8,
    nonce: u32,
    channel_id: ?[]const u8,
    options: VoiceSelect,
) Error!u32 {
    const Select = struct {
        nonce: []const u8,
        cmd: []const u8,
        args: struct {
            channel_id: ?[]const u8,
            timeout: ?i32,
            force: bool,
            navigate: bool,
        },
    };
    var digits: [nonce_digits]u8 = undefined;
    return json.write(buffer, Select, .{
        .nonce = formatNonce(&digits, nonce),
        .cmd = "SELECT_VOICE_CHANNEL",
        .args = .{
            .channel_id = channel_id,
            .timeout = if (options.timeout_seconds > 0) options.timeout_seconds else null,
            .force = options.force,
            .navigate = options.navigate,
        },
    });
}

/// A null `channel_id` leaves the channel the user is in.
///
/// Assumes `checkId` has passed on `channel_id` when one is given.
pub fn selectTextChannel(
    buffer: []u8,
    nonce: u32,
    channel_id: ?[]const u8,
    timeout_seconds: i32,
) Error!u32 {
    const Select = struct {
        nonce: []const u8,
        cmd: []const u8,
        args: struct { channel_id: ?[]const u8, timeout: ?i32 },
    };
    var digits: [nonce_digits]u8 = undefined;
    return json.write(buffer, Select, .{
        .nonce = formatNonce(&digits, nonce),
        .cmd = "SELECT_TEXT_CHANNEL",
        .args = .{
            .channel_id = channel_id,
            .timeout = if (timeout_seconds > 0) timeout_seconds else null,
        },
    });
}

pub fn joinReply(buffer: []u8, nonce: u32, user_id: []const u8, reply: Reply) Error!u32 {
    assert(user_id.len > 0);

    const JoinReply = struct {
        cmd: []const u8,
        args: struct { user_id: []const u8 },
        nonce: []const u8,
    };
    var digits: [nonce_digits]u8 = undefined;
    return json.write(buffer, JoinReply, .{
        .cmd = reply.command(),
        .args = .{ .user_id = user_id },
        .nonce = formatNonce(&digits, nonce),
    });
}

/// A null presence clears the activity: `args` then carries only the process id.
pub fn richPresence(
    buffer: []u8,
    nonce: u32,
    process_id: u32,
    presence: ?*const Presence,
) PresenceError!u32 {
    assert(process_id > 0);

    // Refused before a byte is written: a failed write leaves a fragment in the buffer.
    if (presence) |set| {
        if (set.party_max > 0 and set.party_size > set.party_max) return error.InvalidPresence;
        try checkButtons(set.buttons);
        try checkUrls(set);
        try checkText(set);
    }

    const SetActivity = struct {
        nonce: []const u8,
        cmd: []const u8,
        args: struct {
            pid: u32,
            activity: ?Activity,
        },
    };
    var digits: [nonce_digits]u8 = undefined;
    return json.write(buffer, SetActivity, .{
        .nonce = formatNonce(&digits, nonce),
        .cmd = "SET_ACTIVITY",
        .args = .{
            .pid = process_id,
            .activity = if (presence) |set| .from(set) else null,
        },
    });
}

/// A grouping object exists only when something inside it is set.
const Activity = struct {
    type: ?u8,
    state: ?[]const u8,
    state_url: ?[]const u8,
    details: ?[]const u8,
    details_url: ?[]const u8,
    status_display_type: ?u8,
    timestamps: ?Timestamps,
    assets: ?Assets,
    party: ?Party,
    secrets: ?Secrets,
    buttons: ?[]const Presence.Button,
    instance: bool,

    const Timestamps = struct {
        start: ?i64,
        end: ?i64,
    };

    const Assets = struct {
        large_image: ?[]const u8,
        large_text: ?[]const u8,
        large_url: ?[]const u8,
        small_image: ?[]const u8,
        small_text: ?[]const u8,
        small_url: ?[]const u8,
    };

    const Party = struct {
        id: ?[]const u8,
        size: ?Size,
        privacy: ?u8,

        const Size = struct { u32, u32 };
    };

    const Secrets = struct {
        match: ?[]const u8,
        join: ?[]const u8,
        spectate: ?[]const u8,
    };

    fn from(presence: *const Presence) Activity {
        assert(presence.party_size <= presence.party_max or presence.party_max == 0);

        return .{
            .type = if (presence.activity_type == .playing)
                null
            else
                @backingInt(presence.activity_type),
            .state = optional(presence.state),
            .state_url = optional(presence.state_url),
            .details = optional(presence.details),
            .details_url = optional(presence.details_url),
            .status_display_type = if (presence.status_display_type == .name)
                null
            else
                @backingInt(presence.status_display_type),
            .timestamps = nonEmpty(Timestamps, .{
                .start = presence.start_timestamp,
                .end = presence.end_timestamp,
            }),
            .assets = nonEmpty(Assets, .{
                .large_image = optional(presence.large_image_key),
                .large_text = optional(presence.large_image_text),
                .large_url = optional(presence.large_image_url),
                .small_image = optional(presence.small_image_key),
                .small_text = optional(presence.small_image_text),
                .small_url = optional(presence.small_image_url),
            }),
            .party = nonEmpty(Party, .{
                .id = optional(presence.party_id),
                .size = partySize(presence),
                .privacy = if (presence.party_privacy == .private)
                    null
                else
                    @backingInt(presence.party_privacy),
            }),
            .secrets = nonEmpty(Secrets, .{
                .match = optional(presence.match_secret),
                .join = optional(presence.join_secret),
                .spectate = optional(presence.spectate_secret),
            }),
            .buttons = if (presence.buttons.len > 0) presence.buttons else null,
            .instance = presence.instance,
        };
    }
};

/// Every text field a caller supplies. Leaving one out is a compile error.
fn textFields(presence: *const Presence) [text_field_count]?[]const u8 {
    return .{
        presence.state,
        presence.state_url,
        presence.details,
        presence.details_url,
        presence.large_image_key,
        presence.large_image_text,
        presence.large_image_url,
        presence.small_image_key,
        presence.small_image_text,
        presence.small_image_url,
        presence.party_id,
        presence.match_secret,
        presence.join_secret,
        presence.spectate_secret,
    };
}

const text_field_count = count: {
    var found: usize = 0;
    for (@typeInfo(Presence).@"struct".field_types) |Field| {
        if (Field == ?[]const u8) found += 1;
    }
    break :count found;
};

/// Text must be valid UTF-8, or `std.json` renders it as an array of byte values.
fn checkText(presence: *const Presence) error{InvalidPresence}!void {
    for (textFields(presence)) |field| {
        const value = field orelse continue;
        if (!json.scan.validUtf8(value)) return error.InvalidPresence;
    }
}

/// A label is held to its length, and its URL to what `checkUrl` takes.
fn checkButtons(buttons: []const Presence.Button) error{InvalidPresence}!void {
    if (buttons.len > Presence.max_buttons) return error.InvalidPresence;

    for (buttons) |button| {
        if (button.label.len == 0) return error.InvalidPresence;
        if (button.label.len > Presence.max_button_label_bytes) return error.InvalidPresence;
        if (!json.scan.validUtf8(button.label)) return error.InvalidPresence;

        try checkUrl(Presence.max_button_url_bytes, button.url);
    }
}

/// Held to a web scheme and to printable ASCII, which keeps a URL's escaped worst case equal
/// to its length and so lets the presence buffer be sized from the capacities alone.
fn checkUrl(comptime capacity: u32, url: []const u8) error{InvalidPresence}!void {
    if (url.len > capacity) return error.InvalidPresence;
    if (!json.scan.plain(url)) return error.InvalidPresence;

    const rest = named: {
        for (Presence.url_schemes) |scheme| {
            if (std.mem.startsWith(u8, url, scheme)) break :named url[scheme.len..];
        }
        return error.InvalidPresence;
    };

    // A scheme with nothing behind it names no page.
    if (rest.len == 0) return error.InvalidPresence;
}

/// The links a presence hangs on its text and its images.
fn checkUrls(presence: *const Presence) error{InvalidPresence}!void {
    for ([_]?[]const u8{
        presence.state_url,
        presence.details_url,
        presence.large_image_url,
        presence.small_image_url,
    }) |field| {
        const url = field orelse continue;
        try checkUrl(Presence.max_url_bytes, url);
    }
}

/// Neither half of a party size is meaningful alone, so one without the other reports none.
fn partySize(presence: *const Presence) ?Activity.Party.Size {
    if (presence.party_size == 0) return null;
    if (presence.party_max == 0) return null;

    assert(presence.party_size <= presence.party_max);
    return .{ presence.party_size, presence.party_max };
}

/// An empty string counts as absent: callers zero their struct and fill only what they use.
fn optional(field: ?[]const u8) ?[]const u8 {
    const value = field orelse return null;
    if (value.len == 0) return null;

    // The wire tells absent from present-and-empty, so what survives here carries bytes.
    assert(value.len > 0);
    return value;
}

fn nonEmpty(comptime Group: type, group: Group) ?Group {
    const info = @typeInfo(Group).@"struct";
    inline for (info.field_names, info.field_types) |name, Field| {
        comptime assert(@typeInfo(Field) == .optional);
        if (@field(group, name) != null) return group;
    }
    return null;
}

fn formatNonce(digits: *[nonce_digits]u8, nonce: u32) []const u8 {
    const text = std.fmt.bufPrint(digits, "{d}", .{nonce}) catch unreachable;
    assert(text.len > 0);
    assert(text.len <= nonce_digits);
    return text;
}

test handshake {
    var buffer: [256]u8 = undefined;
    const length = try handshake(&buffer, 1, "111111111111111111");
    try std.testing.expectEqualStrings(
        \\{"v":1,"client_id":"111111111111111111"}
    , buffer[0..length]);
}

test subscription {
    var buffer: [256]u8 = undefined;

    const subscribed = try subscription(&buffer, 1, .subscribe, .activity_join, "");
    try std.testing.expectEqualStrings(
        \\{"nonce":"1","cmd":"SUBSCRIBE","evt":"ACTIVITY_JOIN"}
    , buffer[0..subscribed]);

    const unsubscribed = try subscription(&buffer, 2, .unsubscribe, .activity_join, "");
    try std.testing.expectEqualStrings(
        \\{"nonce":"2","cmd":"UNSUBSCRIBE","evt":"ACTIVITY_JOIN"}
    , buffer[0..unsubscribed]);

    const guilds = try subscription(&buffer, 3, .subscribe, .guild_status, "3333333333");
    try std.testing.expectEqualStrings(
        \\{"nonce":"3","cmd":"SUBSCRIBE","evt":"GUILD_STATUS","args":{"guild_id":"3333333333"}}
    , buffer[0..guilds]);

    const messages = try subscription(&buffer, 4, .subscribe, .message_create, "4444444444");
    try std.testing.expectEqualStrings(
        \\{"nonce":"4","cmd":"SUBSCRIBE","evt":"MESSAGE_CREATE","args":{"channel_id":"4444444444"}}
    , buffer[0..messages]);
}

test getVoiceSettings {
    var buffer: [256]u8 = undefined;
    const length = try getVoiceSettings(&buffer, 5);
    try std.testing.expectEqualStrings(
        \\{"nonce":"5","cmd":"GET_VOICE_SETTINGS"}
    , buffer[0..length]);
}

test setVoiceSettings {
    var buffer: [1024]u8 = undefined;

    // An update naming nothing still names the command, and leaves every object out.
    const nothing: rpc.VoiceSettings.Update = .{};
    try checkVoiceUpdate(&nothing);
    const quiet = try setVoiceSettings(&buffer, 6, &nothing);
    try std.testing.expectEqualStrings(
        \\{"nonce":"6","cmd":"SET_VOICE_SETTINGS","args":{}}
    , buffer[0..quiet]);

    // One field inside an object is enough to write that object and no other.
    const muted: rpc.VoiceSettings.Update = .{ .mute = true, .output_volume = 75 };
    try checkVoiceUpdate(&muted);
    const changed = try setVoiceSettings(&buffer, 7, &muted);
    try std.testing.expectEqualStrings(
        \\{"nonce":"7","cmd":"SET_VOICE_SETTINGS","args":{"output":{"volume":75},"mute":true}}
    , buffer[0..changed]);

    var key: rpc.VoiceSettings.Shortcut = .{ .kind = 0, .code = 12 };
    key.name.set("f12");

    const keys = [_]rpc.VoiceSettings.Shortcut{key};
    const push: rpc.VoiceSettings.Update = .{
        .mode = .push_to_talk,
        .mode_delay = 20,
        .shortcut = &keys,
    };
    try checkVoiceUpdate(&push);
    const bound = try setVoiceSettings(&buffer, 8, &push);
    try std.testing.expectEqualStrings(
        \\{"nonce":"8","cmd":"SET_VOICE_SETTINGS","args":{"mode":{"type":"PUSH_TO_TALK","delay":20,"shortcut":[{"type":0,"code":12,"name":"f12"}]}}}
    , buffer[0..bound]);
}

test setUserVoiceSettings {
    var buffer: [512]u8 = undefined;

    const mix: rpc.UserVoiceSettings = .{ .pan_left = 0.25, .pan_right = 1, .volume = 150 };
    try checkUserVoiceSettings(&mix);
    const length = try setUserVoiceSettings(&buffer, 9, "222222222222222222", &mix);
    try std.testing.expectEqualStrings(
        \\{"nonce":"9","cmd":"SET_USER_VOICE_SETTINGS","args":{"user_id":"222222222222222222","pan":{"left":0.25,"right":1},"volume":150}}
    , buffer[0..length]);
}

test "a pan needs both of its sides, and a level Discord's own ceiling" {
    const half: rpc.UserVoiceSettings = .{ .pan_left = 0.5 };
    try std.testing.expectError(error.InvalidVoiceSettings, checkUserVoiceSettings(&half));

    const other: rpc.UserVoiceSettings = .{ .pan_right = 0.5 };
    try std.testing.expectError(error.InvalidVoiceSettings, checkUserVoiceSettings(&other));

    const loud: rpc.UserVoiceSettings = .{ .volume = rpc.UserVoiceSettings.volume_max + 1 };
    try std.testing.expectError(error.InvalidVoiceSettings, checkUserVoiceSettings(&loud));

    const nowhere: rpc.UserVoiceSettings = .{ .pan_left = std.math.nan(f32), .pan_right = 0 };
    try std.testing.expectError(error.InvalidVoiceSettings, checkUserVoiceSettings(&nowhere));
}

test "a level JSON has no spelling for is refused before it is written" {
    const infinite: rpc.VoiceSettings.Update = .{ .input_volume = std.math.inf(f32) };
    try std.testing.expectError(error.InvalidVoiceSettings, checkVoiceUpdate(&infinite));

    const wide: [rpc.VoiceSettings.device_bytes + 1]u8 = @splat('d');
    const named: rpc.VoiceSettings.Update = .{ .input_device_id = &wide };
    try std.testing.expectError(error.InvalidVoiceSettings, checkVoiceUpdate(&named));

    const keys: [rpc.VoiceSettings.shortcut_capacity + 1]rpc.VoiceSettings.Shortcut = @splat(.{});
    const bound: rpc.VoiceSettings.Update = .{ .shortcut = &keys };
    try std.testing.expectError(error.InvalidVoiceSettings, checkVoiceUpdate(&bound));
}

test certifiedDevices {
    var buffer: [1024]u8 = undefined;

    const device: rpc.CertifiedDevice = .{
        .kind = .audio_input,
        .id = "{0.0.1.00000000}",
        .vendor_name = "vendor-1",
        .vendor_url = "https://example.invalid/vendor",
        .model_name = "model-1",
        .model_url = "https://example.invalid/model",
        .related = &.{"{0.0.0.00000000}"},
        .echo_cancellation = true,
    };
    try checkDevices(&.{device});
    const length = try certifiedDevices(&buffer, 10, &.{device});
    try std.testing.expectEqualStrings(
        \\{"nonce":"10","cmd":"SET_CERTIFIED_DEVICES","args":{"devices":[{"type":"audioinput","id":"{0.0.1.00000000}","vendor":{"name":"vendor-1","url":"https://example.invalid/vendor"},"model":{"name":"model-1","url":"https://example.invalid/model"},"related":["{0.0.0.00000000}"],"echo_cancellation":true}]}}
    , buffer[0..length]);
}

test "device text is held to what the buffer can be sized from" {
    const usable: rpc.CertifiedDevice = .{
        .kind = .video_input,
        .id = "id",
        .vendor_name = "vendor",
        .vendor_url = "url",
        .model_name = "model",
        .model_url = "url",
    };

    var empty_field = usable;
    empty_field.id = "";
    try std.testing.expectError(error.InvalidDevice, checkDevices(&.{empty_field}));

    var wide = usable;
    const long: [rpc.CertifiedDevice.text_bytes + 1]u8 = @splat('d');
    wide.model_name = &long;
    try std.testing.expectError(error.InvalidDevice, checkDevices(&.{wide}));

    var escaped = usable;
    escaped.vendor_name = "a\"b";
    try std.testing.expectError(error.InvalidDevice, checkDevices(&.{escaped}));

    var accented = usable;
    accented.vendor_name = "caf\u{00e9}";
    try std.testing.expectError(error.InvalidDevice, checkDevices(&.{accented}));

    var crowded = usable;
    const related: [rpc.CertifiedDevice.related_capacity + 1][]const u8 = @splat("id");
    crowded.related = &related;
    try std.testing.expectError(error.InvalidDevice, checkDevices(&.{crowded}));

    const many: [rpc.CertifiedDevice.capacity + 1]rpc.CertifiedDevice = @splat(usable);
    try std.testing.expectError(error.InvalidDevice, checkDevices(&many));
}

test "the guild and channel commands name what they ask for" {
    var buffer: [512]u8 = undefined;

    const listed = try getGuilds(&buffer, 11);
    try std.testing.expectEqualStrings(
        \\{"nonce":"11","cmd":"GET_GUILDS"}
    , buffer[0..listed]);

    const one = try getGuild(&buffer, 12, "333333333333333333", 5);
    try std.testing.expectEqualStrings(
        \\{"nonce":"12","cmd":"GET_GUILD","args":{"guild_id":"333333333333333333","timeout":5}}
    , buffer[0..one]);

    // Zero leaves the wait to Discord, so the member is left out entirely.
    const untimed = try getGuild(&buffer, 13, "333333333333333333", 0);
    try std.testing.expectEqualStrings(
        \\{"nonce":"13","cmd":"GET_GUILD","args":{"guild_id":"333333333333333333"}}
    , buffer[0..untimed]);

    const guild_channels = try getChannels(&buffer, 14, "333333333333333333");
    try std.testing.expectEqualStrings(
        \\{"nonce":"14","cmd":"GET_CHANNELS","args":{"guild_id":"333333333333333333"}}
    , buffer[0..guild_channels]);

    const whole = try getChannel(&buffer, 15, "444444444444444444");
    try std.testing.expectEqualStrings(
        \\{"nonce":"15","cmd":"GET_CHANNEL","args":{"channel_id":"444444444444444444"}}
    , buffer[0..whole]);

    const selected = try getSelectedVoiceChannel(&buffer, 16);
    try std.testing.expectEqualStrings(
        \\{"nonce":"16","cmd":"GET_SELECTED_VOICE_CHANNEL"}
    , buffer[0..selected]);
}

test "selecting a channel carries the null that leaves one" {
    var buffer: [512]u8 = undefined;

    const joined = try selectVoiceChannel(&buffer, 17, "444444444444444444", .{
        .timeout_seconds = 3,
        .force = true,
        .navigate = false,
    });
    try std.testing.expectEqualStrings(
        \\{"nonce":"17","cmd":"SELECT_VOICE_CHANNEL","args":{"channel_id":"444444444444444444","timeout":3,"force":true,"navigate":false}}
    , buffer[0..joined]);

    // Leaving names no channel, and the member has to survive as an explicit null.
    const left = try selectVoiceChannel(&buffer, 18, null, .{});
    try std.testing.expectEqualStrings(
        \\{"nonce":"18","cmd":"SELECT_VOICE_CHANNEL","args":{"force":false,"navigate":false}}
    , buffer[0..left]);

    const shown = try selectTextChannel(&buffer, 19, "444444444444444444", 0);
    try std.testing.expectEqualStrings(
        \\{"nonce":"19","cmd":"SELECT_TEXT_CHANNEL","args":{"channel_id":"444444444444444444"}}
    , buffer[0..shown]);
}

test "an id Discord cannot read back is refused" {
    try std.testing.expectError(error.InvalidId, checkId(""));
    try std.testing.expectError(error.InvalidId, checkId("4444444444444444444444"));
    try std.testing.expectError(error.InvalidId, checkId("44444x4444"));
    try std.testing.expectError(error.InvalidId, checkId("-4444444444"));
    try checkId("444444444444444444");
    try checkId("18446744073709551615");
}

test joinReply {
    var buffer: [256]u8 = undefined;

    const accepted = try joinReply(&buffer, 7, "222222222222222222", .yes);
    try std.testing.expectEqualStrings(
        \\{"cmd":"SEND_ACTIVITY_JOIN_INVITE","args":{"user_id":"222222222222222222"},"nonce":"7"}
    , buffer[0..accepted]);

    const ignored = try joinReply(&buffer, 8, "222222222222222222", .ignore);
    const refused = try joinReply(&buffer, 8, "222222222222222222", .no);
    try std.testing.expectEqual(ignored, refused);
}

test authorize {
    var buffer: [256]u8 = undefined;

    const asked = try authorize(&buffer, 4, "111111111111111111", &.{ "rpc", "identify" });
    try std.testing.expectEqualStrings(
        \\{"nonce":"4","cmd":"AUTHORIZE","args":{"client_id":"111111111111111111","scopes":["rpc","identify"]}}
    , buffer[0..asked]);
}

test authenticate {
    var buffer: [256]u8 = undefined;

    const handed = try authenticate(&buffer, 5, "a.token.value");
    try std.testing.expectEqualStrings(
        \\{"nonce":"5","cmd":"AUTHENTICATE","args":{"access_token":"a.token.value"}}
    , buffer[0..handed]);
}

test "richPresence writes only the fields that are set" {
    var buffer: [1024]u8 = undefined;

    const cleared = try richPresence(&buffer, 1, 9999, null);
    try std.testing.expectEqualStrings(
        \\{"nonce":"1","cmd":"SET_ACTIVITY","args":{"pid":9999}}
    , buffer[0..cleared]);

    const presence: Presence = .{
        .state = "state-1",
        .details = "details-1",
        .start_timestamp = 1507665886,
        .large_image_key = "image-1",
        .party_id = "party-1",
        .party_size = 3,
        .party_max = 6,
        .party_privacy = .public,
        .join_secret = "abcdef01",
        .instance = true,
    };
    const length = try richPresence(&buffer, 2, 9999, &presence);
    try std.testing.expectEqualStrings(
        \\{"nonce":"2","cmd":"SET_ACTIVITY","args":{"pid":9999,"activity":{"state":"state-1","details":"details-1","timestamps":{"start":1507665886},"assets":{"large_image":"image-1"},"party":{"id":"party-1","size":[3,6],"privacy":1},"secrets":{"join":"abcdef01"},"instance":true}}}
    , buffer[0..length]);
}

test "an activity carries its type and its links" {
    var buffer: [1024]u8 = undefined;

    const presence: Presence = .{
        .state = "state-1",
        .activity_type = .listening,
        .buttons = &.{
            .{ .label = "First", .url = "https://example.com/one" },
            .{ .label = "Second", .url = "http://example.com/two" },
        },
    };
    const length = try richPresence(&buffer, 3, 9999, &presence);
    try std.testing.expectEqualStrings(
        \\{"nonce":"3","cmd":"SET_ACTIVITY","args":{"pid":9999,"activity":{"type":2,"state":"state-1","buttons":[{"label":"First","url":"https://example.com/one"},{"label":"Second","url":"http://example.com/two"}],"instance":false}}}
    , buffer[0..length]);
}

test "an activity hangs a link on its text and on its images" {
    var buffer: [1024]u8 = undefined;

    const presence: Presence = .{
        .state = "state-1",
        .state_url = "https://example.com/party",
        .details = "details-1",
        .details_url = "https://example.com/match",
        .status_display_type = .details,
        .large_image_key = "image-1",
        .large_image_url = "https://example.com/map",
        .small_image_key = "image-2",
        .small_image_url = "https://example.com/hero",
    };
    const length = try richPresence(&buffer, 4, 9999, &presence);
    try std.testing.expectEqualStrings(
        \\{"nonce":"4","cmd":"SET_ACTIVITY","args":{"pid":9999,"activity":{"state":"state-1","state_url":"https://example.com/party","details":"details-1","details_url":"https://example.com/match","status_display_type":2,"assets":{"large_image":"image-1","large_url":"https://example.com/map","small_image":"image-2","small_url":"https://example.com/hero"},"instance":false}}}
    , buffer[0..length]);
}

test "a link Discord would refuse is refused here" {
    var buffer: [1024]u8 = undefined;
    const long: [Presence.max_url_bytes + 1]u8 = @splat('u');

    for ([_]Presence{
        .{ .state_url = "example.com/no-scheme" },
        .{ .details_url = "ftp://example.com" },
        .{ .large_image_url = "https://example.com/a b" },
        .{ .small_image_url = "https://example.com/\"quoted\"" },
        .{ .state_url = &long },

        // A scheme standing on its own, which is as far as a prefix check alone would look.
        .{ .state_url = "https://" },
        .{ .details_url = "http://" },
    }) |presence| {
        try std.testing.expectError(
            error.InvalidPresence,
            richPresence(&buffer, 1, 9999, &presence),
        );
    }

    // A link within every limit is carried whole.
    const usable: Presence = .{ .state_url = "https://example.com/party" };
    _ = try richPresence(&buffer, 1, 9999, &usable);
}

test "a button Discord would refuse is refused here" {
    var buffer: [1024]u8 = undefined;
    const ok: Presence.Button = .{ .label = "Open", .url = "https://example.com" };
    const long_label: [Presence.max_button_label_bytes + 1]u8 = @splat('x');

    const cases = [_]Presence.Button{
        .{ .label = "", .url = "https://example.com" },
        .{ .label = "Open", .url = "" },
        .{ .label = "Open", .url = "example.com" },
        .{ .label = "Open", .url = "ftp://example.com" },
        .{ .label = "Open", .url = "javascript:alert(1)" },
        .{ .label = "Open", .url = "https://example.com/a b" },
        .{ .label = "Open", .url = "https://example.com/\"" },
        .{ .label = "Open", .url = "https://example.com/\\" },
        .{ .label = "Open", .url = "https://example.com/\n" },
        .{ .label = "Open", .url = "https://" },
        .{ .label = &long_label, .url = "https://example.com" },
    };
    for (cases) |button| {
        const presence: Presence = .{ .buttons = &.{button} };
        try std.testing.expectError(
            error.InvalidPresence,
            richPresence(&buffer, 1, 9999, &presence),
        );
    }

    const too_many: Presence = .{ .buttons = &.{ ok, ok, ok } };
    try std.testing.expectError(
        error.InvalidPresence,
        richPresence(&buffer, 1, 9999, &too_many),
    );

    const accepted: Presence = .{ .buttons = &.{ ok, ok } };
    try std.testing.expect(try richPresence(&buffer, 1, 9999, &accepted) > 0);
}

test "an empty string is omitted" {
    var buffer: [1024]u8 = undefined;

    const presence: Presence = .{
        .state = "",
        .large_image_key = "",
        .party_id = "",
        .join_secret = "",
    };
    const length = try richPresence(&buffer, 1, 9999, &presence);
    try std.testing.expectEqualStrings(
        \\{"nonce":"1","cmd":"SET_ACTIVITY","args":{"pid":9999,"activity":{"instance":false}}}
    , buffer[0..length]);
}

test "a payload larger than the buffer fails loudly" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, handshake(&buffer, 1, "111111111111111111"));
}
