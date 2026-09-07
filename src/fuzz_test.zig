const std = @import("std");
const Smith = std.testing.Smith;
const Io = std.Io;
const Writer = std.Io.Writer;

const Client = @import("Client.zig");
const Presence = @import("Presence.zig");
const User = @import("User.zig");
const text = @import("text.zig");
const rpc = @import("rpc/root.zig");

const parse = rpc.parse;
const serialize = rpc.serialize;
const Scanner = @import("json/root.zig").Scanner;

/// Names the walk dispatches on, so generated members land on real arms.
const member_names = [_][]const u8{
    "cmd",    "evt",           "nonce", "code",   "message",
    "data",   "secret",        "user",  "id",     "username",
    "avatar", "discriminator", "v",     "config", "pad",
};

/// Values Discord uses, so a generated string is sometimes one the parser compares against.
const known_values = [_][]const u8{
    "DISPATCH",              "READY", "ACTIVITY_JOIN", "ACTIVITY_SPECTATE",
    "ACTIVITY_JOIN_REQUEST", "ERROR", "SET_ACTIVITY",  "",
};

const max_gen_depth = 5;

fn genString(smith: *Smith, writer: *Writer) Writer.Error!void {
    if (smith.value(bool)) {
        return writer.print("\"{s}\"", .{known_values[smith.index(known_values.len)]});
    }

    var content: [40]u8 = undefined;
    const length = smith.slice(&content);

    try writer.writeByte('"');
    for (content[0..length]) |character| {
        switch (character) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0...0x1f => try writer.print("\\u{x:0>4}", .{character}),
            0x80...0xff => try writer.writeByte('?'),
            else => try writer.writeByte(character),
        }
    }
    try writer.writeByte('"');
}

fn genValue(smith: *Smith, writer: *Writer, depth: u32) Writer.Error!void {
    if (depth >= max_gen_depth) return writer.writeAll("0");

    switch (smith.index(8)) {
        0, 1, 2 => try genString(smith, writer),
        3 => try writer.print("{d}", .{smith.value(i64)}),
        4 => try writer.writeAll(switch (smith.index(3)) {
            0 => "true",
            1 => "false",
            else => "null",
        }),
        5 => try genObject(smith, writer, depth + 1),
        6 => {
            try writer.writeByte('[');
            var items = smith.index(3);
            while (items > 0) : (items -= 1) {
                try genValue(smith, writer, depth + 1);
                if (items > 1) try writer.writeByte(',');
            }
            try writer.writeByte(']');
        },
        else => try writer.writeAll(if (smith.value(bool)) "[]" else "{}"),
    }
}

fn genObject(smith: *Smith, writer: *Writer, depth: u32) Writer.Error!void {
    try writer.writeByte('{');

    var members = smith.index(6);
    while (members > 0) : (members -= 1) {
        try writer.print("\"{s}\":", .{member_names[smith.index(member_names.len)]});
        try genValue(smith, writer, depth);
        if (members > 1) try writer.writeByte(',');
    }

    try writer.writeByte('}');
}

test "fuzz: the parser survives arbitrary frames" {
    try std.testing.fuzz({}, fuzzParse, .{});
}

fn fuzzParse(_: void, smith: *Smith) anyerror!void {
    var payload: [2048]u8 = undefined;
    var writer: Writer = .fixed(&payload);

    // A full buffer ends the generation, and whatever reached it is the payload.
    genObject(smith, &writer, 0) catch |err| switch (err) {
        error.WriteFailed => {},
    };

    var bytes = writer.buffered();
    // Damage it sometimes, so malformed input carries real structure ahead of the break.
    if (bytes.len > 0 and smith.value(bool)) bytes = bytes[0..smith.index(bytes.len)];

    // A second walk over the same bytes must answer exactly the same.
    const first = parse.frame(bytes) catch |err| switch (err) {
        error.BadPayload => {
            try std.testing.expectError(error.BadPayload, parse.frame(bytes));
            return;
        },
    };

    _ = first.command.slice();
    _ = first.event.slice();
    _ = first.message.slice();
    _ = first.secret.slice();
    _ = first.user.id.slice();
    _ = first.user.username.slice();
    _ = first.user.discriminator.slice();
    _ = first.user.avatar.slice();

    const second = try parse.frame(bytes);
    try std.testing.expect(std.meta.eql(first, second));
}

/// Past the depth a walk carries, so both sides of the refusal are drawn.
const max_probe_depth: u32 = Scanner.max_depth * 4;

/// What one nesting level costs at its widest: `{"` and `":` around the longest member name,
/// and the byte that closes it.
const max_level_bytes: u32 = level: {
    var longest: usize = 0;
    for (member_names) |name| longest = @max(longest, name.len);
    break :level @intCast(4 + longest + 1);
};

// Depths reaching past the bits the scratch holds, which is where the refusal lives.
test "fuzz: nesting is answered the same at every depth" {
    try std.testing.fuzz({}, fuzzNesting, .{});
}

fn fuzzNesting(_: void, smith: *Smith) anyerror!void {
    const depth = 1 + smith.index(max_probe_depth);
    // Cycled per level, so the nesting mixes objects and arrays.
    const pattern = smith.value(u8);
    // Anything but "cmd", whose value the assertion below reads back.
    const buried_under = member_names[1 + smith.index(member_names.len - 1)];

    const payload = try std.testing.allocator.alloc(u8, max_level_bytes * depth + 128);
    defer std.testing.allocator.free(payload);

    var writer: Writer = .fixed(payload);
    try writer.print("{{\"cmd\":\"DISPATCH\",\"{s}\":", .{buried_under});

    var opened: u32 = 0;
    while (opened < depth) : (opened += 1) {
        if (pattern >> @intCast(opened % 8) & 1 == 1) {
            try writer.writeByte('[');
        } else {
            try writer.print("{{\"{s}\":", .{member_names[opened % member_names.len]});
        }
    }
    try writer.writeAll("0");
    while (opened > 0) : (opened -= 1) {
        const level = opened - 1;
        try writer.writeByte(if (pattern >> @intCast(level % 8) & 1 == 1) ']' else '}');
    }
    try writer.writeAll("}");

    const bytes = writer.buffered();
    const walked = parse.frame(bytes);

    // A frame this shallow is inside every bound, so refusing it would be a regression.
    if (depth <= 8) try std.testing.expect(walked != error.BadPayload);

    const result = walked catch |err| switch (err) {
        // Nesting past the bound is refused, which is the other half of what this covers.
        error.BadPayload => return,
    };
    try std.testing.expectEqualStrings("DISPATCH", result.command.slice());
}

// A value large enough to cross `parse.max_value_bytes`, which no generated object approaches.
test "fuzz: an oversized value is refused wherever it sits" {
    try std.testing.fuzz({}, fuzzOversized, .{});
}

fn fuzzOversized(_: void, smith: *Smith) anyerror!void {
    // Straddles the bound, so the run covers both the accepted and the refused side.
    const span = @divExact(parse.max_value_bytes, 8);
    const length = parse.max_value_bytes - @divExact(span, 2) + smith.index(span);
    const escaped = smith.value(bool);

    // An escape is two source bytes for the one byte the walk counts, so it needs twice
    // the room to reach the same bound.
    const room = 2 * (parse.max_value_bytes + span) + 64;
    const payload = try std.testing.allocator.alloc(u8, room);
    defer std.testing.allocator.free(payload);

    var writer: Writer = .fixed(payload);
    // The member name decides whether the walk gathers the value or skips it.
    try writer.print("{{\"{s}\":\"", .{member_names[smith.index(member_names.len)]});

    var counted: u32 = 0;
    while (counted < length) : (counted += 1) {
        if (escaped) try writer.writeAll("\\n") else try writer.writeByte('a');
    }
    try writer.writeAll("\"}");

    const bytes = writer.buffered();
    const result = parse.frame(bytes) catch |err| switch (err) {
        // A value past the bound is refused, which is the side of it this case also covers.
        error.BadPayload => return,
    };

    try std.testing.expect(result.message.len <= parse.text_bytes);
    try std.testing.expect(result.secret.len <= parse.text_bytes);
}

// Escapes wide enough to reach the multi-byte decodes, and the ones that only
// make a character in pairs.
test "fuzz: an escaped string decodes within the room its field has" {
    try std.testing.fuzz({}, fuzzEscapes, .{});
}

fn genEscaped(smith: *Smith, writer: *Writer) Writer.Error!void {
    try writer.print("{{\"{s}\":\"", .{member_names[smith.index(member_names.len)]});

    var pieces: u32 = 0;
    const count = smith.index(64);
    while (pieces < count) : (pieces += 1) {
        switch (smith.index(8)) {
            // Half of a pair: a character only once the other half arrives.
            0 => try writer.print("\\u{x:0>4}", .{0xd800 + smith.index(0x400)}),
            1 => try writer.print("\\u{x:0>4}", .{0xdc00 + smith.index(0x400)}),
            2 => try writer.print("\\u{x:0>4}", .{smith.index(0x10000)}),
            3 => try writer.writeAll("\\\\"),
            4 => try writer.writeAll("\\\""),
            5 => try writer.writeAll("\\u00e9"),
            6 => try writer.writeAll("\\t"),
            else => try writer.writeByte('a' + @as(u8, @intCast(smith.index(26)))),
        }
    }

    try writer.writeAll("\"}");
}

fn fuzzEscapes(_: void, smith: *Smith) anyerror!void {
    var payload: [2048]u8 = undefined;
    var writer: Writer = .fixed(&payload);

    // A full buffer ends the generation, and whatever reached it is the payload.
    genEscaped(smith, &writer) catch |err| switch (err) {
        error.WriteFailed => {},
    };

    var bytes = writer.buffered();
    if (bytes.len > 0 and smith.value(bool)) bytes = bytes[0..smith.index(bytes.len)];

    const result = parse.frame(bytes) catch |err| switch (err) {
        // The generator cuts a payload short on purpose, so a refusal is an outcome too.
        error.BadPayload => return,
    };
    try std.testing.expect(result.message.len <= parse.text_bytes);
}

// Every field at its documented limit, so a failure to fit means the buffer is too small.
test "fuzz: a presence within the documented limits always fits its buffer" {
    try std.testing.fuzz({}, fuzzPresence, .{});
}

fn fuzzPresence(_: void, smith: *Smith) anyerror!void {
    var long: [Presence.max_text_bytes]u8 = undefined;
    var short: [Presence.max_image_key_bytes]u8 = undefined;
    smith.bytes(&long);
    smith.bytes(&short);

    // A URL is held to its own alphabet, so it is drawn from that alphabet.
    var label: [Presence.max_button_label_bytes]u8 = undefined;
    smith.bytes(&label);

    const url_alphabet = "abcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%";
    var url: [Presence.max_button_url_bytes]u8 = undefined;
    @memcpy(url[0.."https://".len], "https://");
    for (url["https://".len..]) |*character| {
        character.* = url_alphabet[smith.index(url_alphabet.len)];
    }

    const button: Presence.Button = .{ .label = &label, .url = &url };
    const buttons = [_]Presence.Button{ button, button };

    const presence: Presence = .{
        .state = &long,
        .details = &long,
        .start_timestamp = smith.value(i64),
        .end_timestamp = smith.value(i64),
        .large_image_key = &short,
        .large_image_text = &long,
        .small_image_key = &short,
        .small_image_text = &long,
        .party_id = &long,
        .party_size = smith.value(u32),
        .party_max = smith.value(u32),
        .party_privacy = if (smith.value(bool)) .public else .private,
        .match_secret = &long,
        .join_secret = &long,
        .spectate_secret = &long,
        .instance = smith.value(bool),
        .kind = switch (smith.index(4)) {
            0 => .playing,
            1 => .listening,
            2 => .watching,
            else => .competing,
        },
        .buttons = buttons[0..smith.index(Presence.max_buttons + 1)],
    };

    var buffer: [Client.max_presence_size]u8 = undefined;
    const nonce = smith.value(u32);
    const written = serialize.richPresence(&buffer, nonce, 9999, &presence);
    const length = written catch |err| switch (err) {
        error.WriteFailed => return error.PresenceDidNotFitItsBuffer,
        // A party larger than its own maximum is refused, which is the documented answer.
        error.InvalidPresence => return,
    };
    try std.testing.expect(length <= Client.max_presence_size);
}

test "fuzz: a join reply always fits one slab slot" {
    try std.testing.fuzz({}, fuzzCommand, .{});
}

fn fuzzCommand(_: void, smith: *Smith) anyerror!void {
    var id: [User.capacityOf("id")]u8 = undefined;
    smith.bytes(&id);

    var buffer: [Client.max_command_size]u8 = undefined;
    const nonce = smith.value(u32);
    const written = serialize.joinReply(&buffer, nonce, &id, .yes);
    const length = written catch |err| switch (err) {
        error.WriteFailed => return error.CommandDidNotFitItsSlot,
    };
    try std.testing.expect(length <= Client.max_command_size);
}

test "fuzz: a text buffer never exceeds its capacity" {
    try std.testing.fuzz({}, fuzzTextBuffer, .{});
}

fn fuzzTextBuffer(_: void, smith: *Smith) anyerror!void {
    const capacity = 64;
    var buffer: text.Buffer(capacity) = .empty;

    var source: [256]u8 = undefined;
    const length = smith.slice(&source);
    buffer.set(source[0..length]);
    try std.testing.expectEqual(@min(length, capacity), buffer.len);

    var pieces: u32 = 0;
    while (pieces < 8) : (pieces += 1) {
        const piece = smith.slice(&source);
        buffer.append(source[0..piece]);
        try std.testing.expect(buffer.len <= capacity);
        try std.testing.expect(buffer.slice().len == buffer.len);
    }

    buffer.clear();
    try std.testing.expectEqual(@as(@TypeOf(buffer).Length, 0), buffer.len);
}
