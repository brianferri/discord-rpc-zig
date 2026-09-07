//! Writing JSON from Zig values whose shape is known at compile time.
//!
//! A payload is a struct, so every key is a literal this resolves before the program runs and
//! every value reaches the writer without passing through a general encoder. A type this has
//! no spelling for is a compile error, which is how a payload gains a shape it cannot write.
//!
//! ```zig
//! const Handshake = struct { v: u32, client_id: []const u8 };
//!
//! var buffer: [64]u8 = undefined;
//! const length = try json.write(&buffer, Handshake, .{ .v = 1, .client_id = "111" });
//! // buffer[0..length] == `{"v":1,"client_id":"111"}`
//! ```
//!
//! | Zig              | JSON                                             |
//! | ---------------- | ------------------------------------------------ |
//! | `?T`             | the value, or the member left out entirely       |
//! | `bool`           | `true` / `false`                                 |
//! | any integer      | a number                                         |
//! | any float        | a number; the caller holds it to the finite ones |
//! | `[]const u8`     | a string, escaped                                |
//! | `[]const T`      | an array                                         |
//! | a tuple          | an array                                         |
//! | a struct         | an object, its field names the keys              |

const std = @import("std");
const assert = std.debug.assert;

pub const Scanner = @import("Scanner.zig");
pub const scan = @import("scan.zig");

pub const Error = std.Io.Writer.Error;

/// Writes `value` into `buffer`, answering how many bytes it took.
pub fn write(buffer: []u8, comptime Value: type, value: Value) Error!u32 {
    assert(buffer.len > 0);

    var writer: std.Io.Writer = .fixed(buffer);
    try emit(&writer, Value, value);

    assert(writer.end > 0);
    return @intCast(writer.end);
}

/// A spelling the program already knows is copied at its own width, so it reaches the buffer
/// as a few stores.
fn literal(writer: *std.Io.Writer, comptime spelling: []const u8) Error!void {
    comptime assert(spelling.len > 0);

    if (writer.end + spelling.len <= writer.buffer.len) {
        @branchHint(.likely);
        writer.buffer[writer.end..][0..spelling.len].* = spelling[0..spelling.len].*;
        writer.end += spelling.len;
        return;
    }
    return writer.writeAll(spelling);
}

pub fn emit(writer: *std.Io.Writer, comptime Value: type, value: Value) Error!void {
    switch (@typeInfo(Value)) {
        .optional => if (value) |present| try emit(writer, @TypeOf(present), present),
        .bool => if (value) try literal(writer, "true") else try literal(writer, "false"),

        .int => try writer.printIntAny(value, 10, .lower, .{}),
        // JSON spells no infinity and no NaN, so every caller is held to finite values first.
        .float => {
            assert(std.math.isFinite(value));
            try writer.printFloat(value, .{ .mode = .decimal });
        },
        .@"struct" => |info| if (info.is_tuple)
            try emitTuple(writer, Value, value)
        else
            try emitObject(writer, Value, value),
        .pointer => |info| switch (info.size) {
            .slice => if (info.child == u8)
                try string(writer, value)
            else
                try emitArray(writer, info.child, value),
            else => @compileError("unwritable payload pointer: " ++ @typeName(Value)),
        },
        else => @compileError("unwritable payload type: " ++ @typeName(Value)),
    }
}

/// A null member is left out, so the separator is placed by what has already been written.
fn emitObject(writer: *std.Io.Writer, comptime Value: type, value: Value) Error!void {
    try writer.writeByte('{');

    var written = false;
    inline for (@typeInfo(Value).@"struct".field_names) |name| {
        const member = @field(value, name);
        const absent = @typeInfo(@TypeOf(member)) == .optional and member == null;
        if (!absent) {
            const spelling = "\"" ++ name ++ "\":";
            if (written) try literal(writer, "," ++ spelling) else try literal(writer, spelling);
            try emit(writer, @TypeOf(member), member);
            written = true;
        }
    }

    try writer.writeByte('}');
}

fn emitTuple(writer: *std.Io.Writer, comptime Value: type, value: Value) Error!void {
    try writer.writeByte('[');
    inline for (@typeInfo(Value).@"struct".field_names, 0..) |name, index| {
        if (index > 0) try writer.writeByte(',');
        try emit(writer, @TypeOf(@field(value, name)), @field(value, name));
    }
    try writer.writeByte(']');
}

fn emitArray(writer: *std.Io.Writer, comptime Item: type, items: []const Item) Error!void {
    try writer.writeByte('[');
    for (items, 0..) |item, index| {
        if (index > 0) try writer.writeByte(',');
        try emit(writer, Item, item);
    }
    try writer.writeByte(']');
}

/// Copied in runs between the bytes JSON spells differently, so text carrying no escape
/// travels as a single copy.
pub fn string(writer: *std.Io.Writer, text: []const u8) Error!void {
    try writer.writeByte('"');

    var copied: usize = 0;
    while (copied < text.len) {
        const found = scan.findEscape(scan.field_widths, text[copied..]);
        if (found.at == text.len - copied) break;

        const index = copied + found.at;
        assert(index < text.len);

        try writer.writeAll(text[copied..index]);
        try emitEscaped(writer, text[index]);

        copied = index + 1;
        assert(copied <= text.len);
    }

    // Every byte left over is one no spelling claimed, so the tail is whole.
    assert(copied <= text.len);
    try writer.writeAll(text[copied..]);

    try writer.writeByte('"');
}

fn emitEscaped(writer: *std.Io.Writer, character: u8) Error!void {
    assert(scan.escapes(character));

    switch (character) {
        '"' => return literal(writer, "\\\""),
        '\\' => return literal(writer, "\\\\"),
        0x08 => return literal(writer, "\\b"),
        0x09 => return literal(writer, "\\t"),
        0x0a => return literal(writer, "\\n"),
        0x0c => return literal(writer, "\\f"),
        0x0d => return literal(writer, "\\r"),

        // The control characters JSON gives no shorthand travel as their code point.
        else => {
            const digits = "0123456789abcdef";
            var spelled = [_]u8{ '\\', 'u', '0', '0', 0, 0 };
            spelled[4] = digits[character >> 4];
            spelled[5] = digits[character & 0xf];
            return writer.writeAll(&spelled);
        },
    }
}

test write {
    const Handshake = struct { v: u32, client_id: []const u8 };

    var buffer: [64]u8 = undefined;
    const length = try write(&buffer, Handshake, .{ .v = 1, .client_id = "111" });
    try std.testing.expectEqualStrings(
        \\{"v":1,"client_id":"111"}
    , buffer[0..length]);
}

test "an absent member is left out, and the separator follows what was written" {
    const Sparse = struct { a: ?u32, b: ?[]const u8, c: bool };

    var buffer: [64]u8 = undefined;

    const first = try write(&buffer, Sparse, .{ .a = null, .b = "x", .c = true });
    try std.testing.expectEqualStrings(
        \\{"b":"x","c":true}
    , buffer[0..first]);

    const every = try write(&buffer, Sparse, .{ .a = null, .b = null, .c = false });
    try std.testing.expectEqualStrings(
        \\{"c":false}
    , buffer[0..every]);
}

test "an array carries its items, and a tuple is one too" {
    var buffer: [128]u8 = undefined;

    const Pair = struct { u32, u32 };
    const Holder = struct { names: []const []const u8, size: Pair };

    const length = try write(&buffer, Holder, .{
        .names = &.{ "one", "two" },
        .size = .{ 3, 6 },
    });
    try std.testing.expectEqualStrings(
        \\{"names":["one","two"],"size":[3,6]}
    , buffer[0..length]);
}

test string {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try string(&writer, "a\"b\\c\nd\te\x01f\x1fg");
    try std.testing.expectEqualStrings(
        \\"a\"b\\c\nd\te\u0001f\u001fg"
    , buffer[0..writer.end]);
}

// The scan reads whole lanes, so a run straddling one is where an off-by-one would show.
test "an escape is found wherever it falls against the scan width" {
    var buffer: [512]u8 = undefined;

    var text: [scan.lanes * 3]u8 = @splat('a');
    for (0..text.len) |index| {
        text = @splat('a');
        text[index] = '"';

        var writer: std.Io.Writer = .fixed(&buffer);
        try string(&writer, &text);

        const written = buffer[0..writer.end];
        try std.testing.expectEqual(text.len + 3, written.len);
        try std.testing.expectEqualStrings("\\\"", written[index + 1 ..][0..2]);
    }
}

test {
    _ = Scanner;
    _ = scan;
    _ = @import("scanner_test.zig");
    _ = @import("fuzz_test.zig");
}
