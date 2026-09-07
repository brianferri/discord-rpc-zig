//! The fuzz suite for the JSON module, with `std.json` as the oracle throughout.
//!
//! Random bytes are JSON about never, so most of what follows generates well-formed input and
//! damages it afterwards. That is what reaches past the first byte and into the walk.

const std = @import("std");
const Smith = std.testing.Smith;
const Writer = std.Io.Writer;

const json = @import("root.zig");
const Scanner = @import("Scanner.zig");
const expectSame = @import("scanner_test.zig").expectSame;

const member_names = [_][]const u8{ "cmd", "evt", "data", "a", "nonce", "user", "id", "" };

const known_text = [_][]const u8{
    "",
    "plain",
    "a\\\"b",
    "\\u00e9",
    "\\ud83d\\ude00",
    "tab\\there",
    "\\\\",
    "\\u0000",
};

/// One value, written as JSON. `depth` is what is left before it must be a leaf.
fn genValue(smith: *Smith, writer: *Writer, depth: u32) Writer.Error!void {
    if (depth == 0) return writer.writeAll("0");

    switch (smith.index(9)) {
        0 => try genObject(smith, writer, depth - 1),
        1 => try genArray(smith, writer, depth - 1),
        2 => try genString(smith, writer),
        3 => try writer.print("{d}", .{smith.value(i32)}),
        4 => try writer.print("{d}.{d}e{d}", .{
            smith.index(1000),
            smith.index(1000),
            @as(i8, @intCast(smith.index(20))) - 10,
        }),
        5 => try writer.writeAll("true"),
        6 => try writer.writeAll("false"),
        7 => try writer.writeAll("null"),
        else => try writer.writeAll(if (smith.value(bool)) "[]" else "{}"),
    }
}

fn genString(smith: *Smith, writer: *Writer) Writer.Error!void {
    return writer.print("\"{s}\"", .{known_text[smith.index(known_text.len)]});
}

fn genObject(smith: *Smith, writer: *Writer, depth: u32) Writer.Error!void {
    try writer.writeByte('{');

    var members = smith.index(5);
    var written = false;
    while (members > 0) : (members -= 1) {
        if (written) try writer.writeByte(',');
        try writer.print("\"{s}\":", .{member_names[smith.index(member_names.len)]});
        try genValue(smith, writer, depth);
        written = true;
    }

    try writer.writeByte('}');
}

fn genArray(smith: *Smith, writer: *Writer, depth: u32) Writer.Error!void {
    try writer.writeByte('[');

    var items = smith.index(5);
    var written = false;
    while (items > 0) : (items -= 1) {
        if (written) try writer.writeByte(',');
        try genValue(smith, writer, depth);
        written = true;
    }

    try writer.writeByte(']');
}

/// Generates a document, then damages it as often as not: a truncation, a byte flipped, or a
/// stretch of whitespace where JSON allows one.
fn generate(smith: *Smith, buffer: []u8) []u8 {
    var writer: Writer = .fixed(buffer);
    genValue(smith, &writer, 4) catch {};

    var bytes = writer.buffered();
    if (bytes.len == 0) return bytes;

    switch (smith.index(6)) {
        0 => bytes = bytes[0..smith.index(bytes.len)],
        1 => bytes[smith.index(bytes.len)] = smith.value(u8),
        2 => bytes[smith.index(bytes.len)] = " \t\n\r"[smith.index(4)],
        else => {},
    }
    return bytes;
}

test "fuzz: the scanners agree on generated documents" {
    try std.testing.fuzz({}, fuzzGenerated, .{});
}

fn fuzzGenerated(_: void, smith: *Smith) anyerror!void {
    var buffer: [4 * 1024]u8 = undefined;
    try expectSame(generate(smith, &buffer));
}

test "fuzz: the scanners agree on arbitrary bytes" {
    try std.testing.fuzz({}, fuzzArbitrary, .{});
}

fn fuzzArbitrary(_: void, smith: *Smith) anyerror!void {
    var source: [192]u8 = undefined;
    const length = smith.slice(&source);
    try expectSame(source[0..length]);
}

// This module spells its own strings, so what it writes is held to what a general encoder
// gives for the same text.
test "fuzz: a written string matches the general encoder" {
    try std.testing.fuzz({}, fuzzString, .{});
}

fn fuzzString(_: void, smith: *Smith) anyerror!void {
    var source: [96]u8 = undefined;
    const length = smith.slice(&source);
    const text = source[0..length];

    // Text reaching here has already been held to valid UTF-8 by its caller.
    if (!std.unicode.utf8ValidateSlice(text)) return;

    var mine_buffer: [1024]u8 = undefined;
    var mine: Writer = .fixed(&mine_buffer);
    try json.string(&mine, text);

    var theirs_buffer: [1024]u8 = undefined;
    var theirs: Writer = .fixed(&theirs_buffer);
    try std.json.Stringify.value(text, .{
        .whitespace = .minified,
        .escape_unicode = false,
    }, &theirs);

    try std.testing.expectEqualStrings(theirs.buffered(), mine.buffered());
}

// What this module writes, this module must be able to read back.
test "fuzz: a written document scans back to what went in" {
    try std.testing.fuzz({}, fuzzRoundTrip, .{});
}

fn fuzzRoundTrip(_: void, smith: *Smith) anyerror!void {
    var source: [96]u8 = undefined;
    const length = smith.slice(&source);
    const text = source[0..length];
    if (!std.unicode.utf8ValidateSlice(text)) return;

    const Held = struct {
        text: []const u8,
        count: i32,
        flag: bool,
        absent: ?u32,
    };
    const held: Held = .{
        .text = text,
        .count = smith.value(i32),
        .flag = smith.value(bool),
        .absent = null,
    };

    var buffer: [1024]u8 = undefined;
    const written = try json.write(&buffer, Held, held);

    var scanner: Scanner = .init(buffer[0..written]);
    try std.testing.expectEqual(Scanner.Kind.object_begin, try scanner.next());

    try std.testing.expectEqual(Scanner.Kind.string, try scanner.next());
    try std.testing.expectEqualStrings("text", scanner.value);

    try std.testing.expectEqual(Scanner.Kind.string, try scanner.next());
    var read: [96]u8 = undefined;
    const decoded = try Scanner.unescape(&read, scanner.value);
    try std.testing.expectEqual(text.len, decoded);
    try std.testing.expectEqualStrings(text, read[0..decoded]);

    // `absent` was null, so the object holds the three that were not.
    try std.testing.expectEqual(Scanner.Kind.string, try scanner.next());
    try std.testing.expectEqualStrings("count", scanner.value);
    try std.testing.expectEqual(Scanner.Kind.number, try scanner.next());
    try std.testing.expectEqual(held.count, try std.fmt.parseInt(i32, scanner.value, 10));

    try std.testing.expectEqual(Scanner.Kind.string, try scanner.next());
    try std.testing.expectEqualStrings("flag", scanner.value);
    try std.testing.expectEqual(
        @as(Scanner.Kind, if (held.flag) .true else .false),
        try scanner.next(),
    );

    try std.testing.expectEqual(Scanner.Kind.object_end, try scanner.next());
    try std.testing.expectEqual(Scanner.Kind.end_of_document, try scanner.next());
}

// Passing over a value must land where reading it whole would have.
test "fuzz: skipping a value lands where reading it does" {
    try std.testing.fuzz({}, fuzzSkip, .{});
}

fn fuzzSkip(_: void, smith: *Smith) anyerror!void {
    var buffer: [4 * 1024]u8 = undefined;

    var writer: Writer = .fixed(&buffer);
    // A document deeper than the buffer holds is one this target has nothing to say about.
    genValue(smith, &writer, 4) catch return;
    const document = writer.buffered();
    std.debug.assert(document.len > 0);

    var skipping: Scanner = .init(document);
    var reading: Scanner = .init(document);

    try skipping.skipValue();

    // The same value, taken token by token instead.
    const depth = reading.stackHeight();
    switch (try reading.next()) {
        .object_begin, .array_begin => try reading.skipUntil(depth),
        .object_end, .array_end, .end_of_document => unreachable,
        else => {},
    }

    try std.testing.expectEqual(reading.cursor, skipping.cursor);
    try std.testing.expectEqual(reading.stackHeight(), skipping.stackHeight());
}
