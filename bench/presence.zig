//! A fixed workload per code path, one case per run so a profiler attributes cleanly.
//!
//!   zig build bench
//!   valgrind --tool=cachegrind --cache-sim=yes zig-out/bin/bench parse_ready
//!
//! `list` names every case; `none` is the baseline to subtract.

const std = @import("std");
const Io = std.Io;
const discord = @import("discord_rpc");

const parse = discord.rpc.parse;
const serialize = discord.rpc.serialize;
const text = discord.text;
const Presence = discord.Presence;
const Client = discord.Client;

const rounds: u32 = 20_000;

// Discord sends a frame as one line, so these carry no whitespace a walk would skip.
const ready =
    \\{"cmd":"DISPATCH","evt":"READY","data":{"v":1,"config":{"cdn_host":"cdn.discordapp.com","api_endpoint":"//discord.com/api","environment":"production"},"user":{"id":"5010738435956","username":"bioclastic","discriminator":"0","global_name":"Bio","avatar":"a1b2c3d4e5f6","avatar_decoration_data":null,"bot":false,"flags":0,"premium_type":0}}}
;

const errored =
    \\{"cmd":"SET_ACTIVITY","evt":"ERROR","data":{"code":4000,"message":"Invalid Client ID"},"nonce":"7"}
;

const joined =
    \\{"cmd":"DISPATCH","evt":"ACTIVITY_JOIN","data":{"secret":"8f21:eu-west:tok_9c2"}}
;

const join_request =
    \\{"cmd":"DISPATCH","evt":"ACTIVITY_JOIN_REQUEST","data":{"user":{"id":"5010738435956","username":"bioclastic","discriminator":"0","avatar":"a1b2c3d4e5f6"}}}
;

/// Members the walk knows nothing about, so every one is skipped whole.
const unknown =
    \\{"cmd":"DISPATCH","evt":"READY","data":{"a":[1,2,3,4,5],"b":{"c":{"d":"e"}},"f":true,"g":null,"h":12345678,"i":"a string of some length","j":[{"k":1},{"k":2}],"l":{}}}
;

/// Text carrying every character JSON spells differently, which is the escaper's slow path.
const escaped =
    \\{"cmd":"DISPATCH","evt":"ACTIVITY_JOIN","data":{"secret":"a\"b\\c\nd\te\u0001f\u001fgh\ri\bj\fk"}}
;

const malformed =
    \\{"cmd":"DISPATCH","evt":"READY","data":{"user":{"id":"501073843595
;

/// A dispatch a client walks twice: once for the frame, once for what the event carries.
const message =
    \\{"cmd":"DISPATCH","evt":"MESSAGE_CREATE","data":{"channel_id":"501073843595640833","message":{"id":"501073843595640901","content":"the quick brown fox jumps over the lazy dog","nick":"bioclastic","author":{"id":"5010738435956","username":"bioclastic","discriminator":"0","avatar":"a1b2c3d4e5f6"},"timestamp":"2026-09-08T20:00:00+00:00","tts":false,"mention_everyone":false,"pinned":false,"type":0}}}
;

/// The deepest reply the protocol carries: three nested objects, two device arrays and the
/// only floats a walk parses.
const voice_settings =
    \\{"cmd":"GET_VOICE_SETTINGS","evt":null,"nonce":"1","data":{"input":{"device_id":"alsa_input.pci-0000_00_1f.3.analog-stereo","volume":51.5,"available_devices":[{"id":"default","name":"Default"},{"id":"alsa_input.pci-0000_00_1f.3.analog-stereo","name":"Built-in Audio Analog Stereo"}]},"output":{"device_id":"alsa_output.pci-0000_00_1f.3.analog-stereo","volume":140.25,"available_devices":[{"id":"default","name":"Default"},{"id":"alsa_output.pci-0000_00_1f.3.analog-stereo","name":"Built-in Audio Analog Stereo"}]},"mode":{"type":"PUSH_TO_TALK","auto_threshold":false,"threshold":-52.5,"delay":21.5,"shortcut":[{"type":0,"code":12,"name":"f12"},{"type":2,"code":16,"name":"shift"}]},"automatic_gain_control":true,"echo_cancellation":false,"noise_suppression":true,"qos":true,"silence_warning":false,"deaf":false,"mute":true}}
;

const full: Presence = .{
    .state = "In the lobby",
    .details = "Counter: 1234",
    .start_timestamp = 1507665886,
    .end_timestamp = 1507665986,
    .large_image_key = "image-1",
    .large_image_text = "the large one",
    .small_image_key = "image-2",
    .small_image_text = "the small one",
    .party_id = "party-1",
    .party_size = 3,
    .party_max = 6,
    .party_privacy = .public,
    .match_secret = "abcdef01",
    .join_secret = "abcdef02",
    .spectate_secret = "abcdef03",
    .instance = true,
};

const minimal: Presence = .{ .state = "In the lobby" };

const buttons = [_]Presence.Button{
    .{ .label = "Website", .url = "https://example.invalid/one" },
    .{ .label = "Discord", .url = "https://example.invalid/two" },
};

const with_buttons: Presence = .{
    .state = "In the lobby",
    .details = "Counter: 1234",
    .activity_type = .listening,
    .buttons = &buttons,
};

/// Every field carrying characters the escaper has to spell out.
const with_escapes: Presence = .{
    .state = "quote \" backslash \\ newline \n tab \t",
    .details = "control \x01 and \x1f and more \"\\",
    .party_id = "a\tb\nc",
};

const Error = std.Io.Writer.Error || serialize.PresenceError;

const Case = struct {
    name: []const u8,
    run: *const fn () Error!usize,
    bytes: usize,
};

const cases = [_]Case{
    .{ .name = "none", .run = benchNone, .bytes = 0 },

    .{ .name = "parse_ready", .run = benchReady, .bytes = ready.len },
    .{ .name = "parse_error", .run = benchErrored, .bytes = errored.len },
    .{ .name = "parse_join", .run = benchJoined, .bytes = joined.len },
    .{ .name = "parse_join_request", .run = benchJoinRequest, .bytes = join_request.len },
    .{ .name = "parse_unknown", .run = benchUnknown, .bytes = unknown.len },
    .{ .name = "parse_escaped", .run = benchEscaped, .bytes = escaped.len },
    .{ .name = "parse_malformed", .run = benchMalformed, .bytes = malformed.len },

    // What a client actually does with a dispatch: the frame walk, then the payload walk.
    .{ .name = "parse_message_frame", .run = benchMessageFrame, .bytes = message.len },
    .{ .name = "parse_message_payload", .run = benchMessagePayload, .bytes = message.len },
    .{ .name = "parse_message_both", .run = benchMessageBoth, .bytes = message.len },

    .{ .name = "parse_voice_settings", .run = benchVoiceSettings, .bytes = voice_settings.len },
    .{ .name = "parse_guilds", .run = benchGuilds, .bytes = guilds.len },
    .{ .name = "event_from_name", .run = benchEventName, .bytes = 20 },

    .{ .name = "serialize_full", .run = benchFull, .bytes = 425 },
    .{ .name = "serialize_minimal", .run = benchMinimal, .bytes = 96 },
    .{ .name = "serialize_buttons", .run = benchButtons, .bytes = 234 },
    .{ .name = "serialize_escapes", .run = benchEscapes, .bytes = 190 },
    .{ .name = "serialize_clear", .run = benchClear, .bytes = 52 },
    .{ .name = "serialize_handshake", .run = benchHandshake, .bytes = 38 },
    .{ .name = "serialize_join_reply", .run = benchJoinReply, .bytes = 96 },
    .{ .name = "serialize_subscription", .run = benchSubscription, .bytes = 54 },
    .{ .name = "serialize_subscription_keyed", .run = benchSubscriptionKeyed, .bytes = 97 },
    .{ .name = "serialize_authorize", .run = benchAuthorize, .bytes = 104 },
    .{ .name = "serialize_voice_settings", .run = benchSetVoiceSettings, .bytes = 176 },
    .{ .name = "serialize_certified", .run = benchCertifiedDevices, .bytes = 466 },

    .{ .name = "text_set", .run = benchTextSet, .bytes = 64 },
};

pub fn main(init: std.process.Init) !void {
    var arguments: std.process.Args.Iterator = .init(init.minimal.args);
    _ = arguments.skip();
    const wanted = arguments.next() orelse "list";

    var out_buffer: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(init.io, &out_buffer);
    const writer = &out.interface;
    defer writer.flush() catch {};

    if (std.mem.eql(u8, wanted, "list")) {
        for (cases) |case| try writer.print("{s} {d}\n", .{ case.name, case.bytes });
        return;
    }

    for (cases) |case| {
        if (!std.mem.eql(u8, wanted, case.name)) continue;
        const sink = try case.run();
        try writer.print("{s} rounds={d} bytes={d} sink={d}\n", .{
            case.name,
            rounds,
            case.bytes,
            sink,
        });
        return;
    }

    try writer.print("unknown case: {s}\n", .{wanted});
    return error.UnknownCase;
}

fn benchNone() Error!usize {
    var sink: usize = 0;
    var round: u32 = 0;
    while (round < rounds) : (round += 1) sink +%= round;
    return sink;
}

/// The payload whole, which is how a frame is walked once it is off the wire.
/// A guild list filled to its capacity, which is the widest record a reply fills.
const guilds = list: {
    var text_out: []const u8 = "{\"cmd\":\"GET_GUILDS\",\"nonce\":\"1\",\"data\":{\"guilds\":[";
    for (0..discord.rpc.GuildList.capacity) |index| {
        if (index > 0) text_out = text_out ++ ",";
        text_out = text_out ++ std.fmt.comptimePrint(
            "{{\"id\":\"5010738435956408{d:0>2}\",\"name\":\"a guild named {d}\"}}",
            .{ index, index },
        );
    }
    break :list text_out ++ "]}}";
};

fn benchMessageFrame() Error!usize {
    return walkAll(message);
}

fn benchMessagePayload() Error!usize {
    var payload: discord.rpc.Payload = .none;
    var sink: usize = 0;

    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        parse.into(
            .{ .notice = .{ .event = .message_create, .out = &payload } },
            message,
        ) catch {
            sink +%= 1;
            continue;
        };
        sink +%= payload.message.content.len;
    }
    return sink;
}

fn benchMessageBoth() Error!usize {
    return (try benchMessageFrame()) +% (try benchMessagePayload());
}

fn benchVoiceSettings() Error!usize {
    var settings: discord.rpc.VoiceSettings = .empty;
    var sink: usize = 0;

    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        parse.into(.{ .voice_settings = &settings }, voice_settings) catch {
            sink +%= 1;
            continue;
        };
        sink +%= settings.input.device_count +% settings.mode.shortcut_count;
    }
    return sink;
}

fn benchGuilds() Error!usize {
    var listed: discord.rpc.GuildList = .empty;
    var sink: usize = 0;

    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        parse.into(.{ .guilds = &listed }, guilds) catch {
            sink +%= 1;
            continue;
        };
        sink +%= listed.count;
    }
    return sink;
}

/// Run for every dispatch frame, so its cost lands on every event a client reports.
///
/// The name rotates, since one held still is a name the compiler answers at build time.
fn benchEventName() Error!usize {
    const spellings = [_][]const u8{
        "MESSAGE_CREATE",
        "ACTIVITY_JOIN",
        "SPEAKING_START",
        "VOICE_STATE_UPDATE",
        "ENTITLEMENT_DELETE",
        "SOMETHING_ELSE",
    };

    var sink: usize = 0;
    var next: usize = 0;

    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        const raised = discord.rpc.Event.fromName(spellings[next]);
        sink +%= if (raised) |found| @backingInt(found) else 0;

        next += 1;
        if (next == spellings.len) next = 0;
    }
    return sink;
}

fn walkAll(payload: []const u8) Error!usize {
    var sink: usize = 0;

    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        const frame = parse.frame(payload) catch |err| switch (err) {
            error.BadPayload => {
                sink +%= 1;
                continue;
            },
        };
        sink +%= frame.user.username.len + frame.secret.len + frame.message.len;
    }
    return sink;
}

fn benchReady() Error!usize {
    return walkAll(ready);
}
fn benchErrored() Error!usize {
    return walkAll(errored);
}
fn benchJoined() Error!usize {
    return walkAll(joined);
}
fn benchJoinRequest() Error!usize {
    return walkAll(join_request);
}
fn benchUnknown() Error!usize {
    return walkAll(unknown);
}
fn benchEscaped() Error!usize {
    return walkAll(escaped);
}
fn benchMalformed() Error!usize {
    return walkAll(malformed);
}

fn writePresence(presence: ?*const Presence) Error!usize {
    var buffer: [Client.max_presence_size]u8 = undefined;
    var sink: usize = 0;

    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        sink +%= try serialize.richPresence(&buffer, round, 9999, presence);
    }
    return sink;
}

fn benchFull() Error!usize {
    return writePresence(&full);
}
fn benchMinimal() Error!usize {
    return writePresence(&minimal);
}
fn benchButtons() Error!usize {
    return writePresence(&with_buttons);
}
fn benchEscapes() Error!usize {
    return writePresence(&with_escapes);
}
fn benchClear() Error!usize {
    return writePresence(null);
}

fn benchHandshake() Error!usize {
    var buffer: [Client.max_command_size]u8 = undefined;
    var sink: usize = 0;

    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        sink +%= try serialize.handshake(&buffer, 1, "1546184199860396062");
    }
    return sink;
}

fn benchJoinReply() Error!usize {
    var buffer: [Client.max_command_size]u8 = undefined;
    var sink: usize = 0;

    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        sink +%= try serialize.joinReply(&buffer, round, "501073843595640833", .yes);
    }
    return sink;
}

fn benchSubscription() Error!usize {
    var buffer: [Client.max_command_size]u8 = undefined;
    var sink: usize = 0;

    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        sink +%= try serialize.subscription(&buffer, round, .subscribe, .activity_join, "");
    }
    return sink;
}

/// The keyed arm, which writes the `args` a global subscription leaves out.
fn benchSubscriptionKeyed() Error!usize {
    var buffer: [Client.max_command_size]u8 = undefined;
    var sink: usize = 0;

    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        sink +%= try serialize.subscription(
            &buffer,
            round,
            .subscribe,
            .message_create,
            "501073843595640833",
        );
    }
    return sink;
}

/// The only command carrying a slice of slices.
fn benchAuthorize() Error!usize {
    var buffer: [Client.max_command_size]u8 = undefined;
    var sink: usize = 0;

    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        sink +%= try serialize.authorize(&buffer, round, "1546184199860396062", &.{
            "rpc",
            "identify",
            "rpc.voice.read",
        });
    }
    return sink;
}

/// The only command writing floats.
fn benchSetVoiceSettings() Error!usize {
    var buffer: [Client.max_bulk_command_size]u8 = undefined;
    var sink: usize = 0;

    var key: discord.rpc.VoiceSettings.Shortcut = .{ .kind = 0, .code = 12 };
    key.name.set("f12");
    const keys = [_]discord.rpc.VoiceSettings.Shortcut{key};

    const update: discord.rpc.VoiceSettings.Update = .{
        .input_device_id = "alsa_input.pci-0000_00_1f.3.analog-stereo",
        .input_volume = 51.5,
        .mode = .push_to_talk,
        .mode_threshold = -52.5,
        .mode_delay = 21.5,
        .shortcut = &keys,
        .mute = true,
    };

    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        sink +%= try serialize.setVoiceSettings(&buffer, round, &update);
    }
    return sink;
}

fn benchCertifiedDevices() Error!usize {
    var buffer: [Client.max_bulk_command_size]u8 = undefined;
    var sink: usize = 0;

    const related = [_][]const u8{"{0.0.0.00000000}.{9a1b2c3d}"};
    const device: discord.rpc.CertifiedDevice = .{
        .kind = .audio_input,
        .id = "{0.0.1.00000000}.{1a2b3c4d}",
        .vendor_name = "an example vendor",
        .vendor_url = "https://example.invalid/vendor",
        .model_name = "an example headset",
        .model_url = "https://example.invalid/model",
        .related = &related,
        .echo_cancellation = true,
        .noise_suppression = true,
    };
    const devices = [_]discord.rpc.CertifiedDevice{device};

    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        sink +%= try serialize.certifiedDevices(&buffer, round, &devices);
    }
    return sink;
}

fn benchTextSet() Error!usize {
    const source = "a reasonably long piece of text that fills the buffer up";
    var buffer: text.Buffer(64) = .empty;
    var sink: usize = 0;

    // The length walks a byte at a time, so the copy survives the optimizer and the case
    // times the copy alone.
    var length: usize = 1;

    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        buffer.set(source[0..length]);
        std.mem.doNotOptimizeAway(&buffer);
        sink +%= buffer.len;

        length += 1;
        if (length > source.len) length = 1;
    }
    return sink;
}
