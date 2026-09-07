//! Reading JSON that is whole before the walk starts.
//!
//! Every byte is in hand, so there is no refill to check, no token arriving in pieces and no
//! allocator: nesting rides a fixed stack and a string is answered as the slice it occupies in
//! the input. A caller that wants the text behind an escape asks `unescape` for it.
//!
//! `next` answers a `Kind` and leaves any bytes that came with it in `value`, so the token
//! itself stays in a register.
//!
//! ```zig
//! var scanner: Scanner = .init(payload);
//! while (true) switch (try scanner.next()) {
//!     .object_begin => {},
//!     .string => useKey(scanner.value),
//!     .end_of_document => break,
//!     else => {},
//! };
//! ```

const std = @import("std");
const assert = std.debug.assert;

const scan = @import("scan.zig");

const Scanner = @This();

pub const Error = error{BadPayload};

/// How deep an object or array may nest. Discord's own frames reach four.
pub const max_depth = 32;

pub const Kind = enum(u8) {
    object_begin,
    object_end,
    array_begin,
    array_end,
    /// `value` holds the bytes between the quotes, still as the input spells them.
    string,
    /// `value` holds the number as written.
    number,
    true,
    false,
    null,
    end_of_document,
};

/// A separator promises another member, so what may follow one is narrower than what may open
/// a container. Keeping the two apart is what refuses a trailing comma.
const State = enum {
    /// A value, or the bracket closing an array nothing was put in.
    value_or_end,
    /// A value, and nothing else.
    value,
    /// A member name, or the brace closing an object nothing was put in.
    key_or_end,
    /// A member name, and nothing else.
    key,
    /// The colon between a name and its value.
    colon,
    /// A value has just been read; a separator or a closer follows it.
    post_value,
};

input: []const u8,
cursor: usize,
state: State,
depth: u32,
/// One bit per open container, set for an object and clear for an array.
containers: std.bit_set.IntegerBitSet(max_depth),
/// The bytes the last `.string` or `.number` carried.
value: []const u8,
/// Set when the last `.string` holds an escape, so its text costs a pass to read.
escaped: bool,

pub fn init(input: []const u8) Scanner {
    return .{
        .input = input,
        .cursor = 0,
        .state = .value,
        .depth = 0,
        .containers = .{ .mask = 0 },
        .value = &.{},
        .escaped = false,
    };
}

/// How many containers are open. A value at the top level sits at zero.
pub fn stackHeight(scanner: *const Scanner) u32 {
    return scanner.depth;
}

pub fn next(scanner: *Scanner) Error!Kind {
    while (true) {
        scanner.skipWhitespace();

        switch (scanner.state) {
            .value, .value_or_end => return scanner.readValue(),
            .key, .key_or_end => return scanner.readKey(),
            .colon => {
                if (scanner.take() != ':') return error.BadPayload;
                scanner.state = .value;
            },
            .post_value => if (try scanner.readSeparator()) |kind| return kind,
        }
    }
}

/// The kind the next `next` will answer, read from its opening byte. Nothing is tokenised, so
/// asking costs a fraction of taking.
pub fn peek(scanner: *const Scanner) Error!Kind {
    var cursor = scanner.cursor;
    var state = scanner.state;

    while (true) {
        cursor = skipSpaceAt(scanner.input, cursor);

        if (cursor == scanner.input.len) {
            if (state == .post_value and scanner.depth == 0) return .end_of_document;
            return error.BadPayload;
        }
        const character = scanner.input[cursor];

        switch (state) {
            .value, .value_or_end => return classify(character, state),
            .key, .key_or_end => {
                if (character == '"') return .string;
                if (character == '}' and state == .key_or_end) return .object_end;
                return error.BadPayload;
            },
            .colon => {
                if (character != ':') return error.BadPayload;
                cursor += 1;
                state = .value;
            },
            .post_value => {
                if (scanner.depth == 0) return error.BadPayload;
                const in_object = scanner.containers.isSet(scanner.depth - 1);

                switch (character) {
                    ',' => {
                        cursor += 1;
                        state = if (in_object) .key else .value;
                    },
                    '}' => return if (in_object) .object_end else error.BadPayload,
                    ']' => return if (in_object) error.BadPayload else .array_end,
                    else => return error.BadPayload,
                }
            },
        }
    }
}

fn classify(character: u8, state: State) Error!Kind {
    return switch (character) {
        '{' => .object_begin,
        '[' => .array_begin,
        '"' => .string,
        '-', '0'...'9' => .number,
        't' => .true,
        'f' => .false,
        'n' => .null,
        ']' => if (state == .value_or_end) .array_end else error.BadPayload,
        else => error.BadPayload,
    };
}

/// Fewer bytes than ASCII counts as space: JSON gives no meaning to a vertical tab or a form
/// feed, so `std.ascii.whitespace` would take input this has to refuse.
///
/// A frame carries none of these at all, so the walk is written for the byte that ends the
/// run being the first one looked at.
fn skipSpaceAt(input: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < input.len) : (cursor += 1) {
        switch (input[cursor]) {
            ' ', '\t', '\n', '\r' => {},
            else => return cursor,
        }
    }
    return cursor;
}

/// Passes over one whole value, whatever it is made of.
pub fn skipValue(scanner: *Scanner) Error!void {
    const depth = scanner.depth;

    switch (try scanner.next()) {
        .object_begin, .array_begin => try scanner.skipUntil(depth),
        .object_end, .array_end, .end_of_document => return error.BadPayload,
        else => {},
    }

    assert(scanner.depth == depth);
}

/// Reads until the open containers are back down to `depth`.
pub fn skipUntil(scanner: *Scanner, depth: u32) Error!void {
    while (scanner.depth > depth) {
        switch (try scanner.next()) {
            .end_of_document => return error.BadPayload,
            else => {},
        }
    }
}

fn readValue(scanner: *Scanner) Error!Kind {
    // A document is a value, so input that ran out before one is input that carried none.
    const character = scanner.peekByte() orelse return error.BadPayload;

    switch (character) {
        '{' => return scanner.open(.object_begin),
        '[' => return scanner.open(.array_begin),
        '"' => {
            scanner.cursor += 1;
            try scanner.readString();
            scanner.state = .post_value;
            return .string;
        },
        '-', '0'...'9' => {
            try scanner.readNumber();
            scanner.state = .post_value;
            return .number;
        },
        't' => return scanner.readLiteral("true", .true),
        'f' => return scanner.readLiteral("false", .false),
        'n' => return scanner.readLiteral("null", .null),

        // An array nothing was put in closes where a value would otherwise begin.
        ']' => {
            if (scanner.state != .value_or_end) return error.BadPayload;
            assert(scanner.depth > 0);
            assert(!scanner.containers.isSet(scanner.depth - 1));
            return scanner.close(.array_end);
        },
        else => return error.BadPayload,
    }
}

fn readKey(scanner: *Scanner) Error!Kind {
    const character = scanner.peekByte() orelse return error.BadPayload;

    switch (character) {
        '"' => {
            scanner.cursor += 1;
            try scanner.readString();
            scanner.state = .colon;
            return .string;
        },
        '}' => {
            if (scanner.state != .key_or_end) return error.BadPayload;
            assert(scanner.depth > 0);
            return scanner.close(.object_end);
        },
        else => return error.BadPayload,
    }
}

/// What follows a value: another member, or the end of what holds it.
fn readSeparator(scanner: *Scanner) Error!?Kind {
    const character = scanner.peekByte() orelse {
        if (scanner.depth > 0) return error.BadPayload;
        return .end_of_document;
    };

    if (scanner.depth == 0) return error.BadPayload;
    const in_object = scanner.containers.isSet(scanner.depth - 1);

    switch (character) {
        ',' => {
            scanner.cursor += 1;
            scanner.state = if (in_object) .key else .value;
            return null;
        },
        '}' => {
            if (!in_object) return error.BadPayload;
            return try scanner.close(.object_end);
        },
        ']' => {
            if (in_object) return error.BadPayload;
            return try scanner.close(.array_end);
        },
        else => return error.BadPayload,
    }
}

fn open(scanner: *Scanner, kind: Kind) Error!Kind {
    if (scanner.depth == max_depth) return error.BadPayload;

    scanner.cursor += 1;
    scanner.containers.setValue(scanner.depth, kind == .object_begin);
    scanner.depth += 1;
    scanner.state = if (kind == .object_begin) .key_or_end else .value_or_end;

    assert(scanner.depth <= max_depth);
    return kind;
}

fn close(scanner: *Scanner, kind: Kind) Error!Kind {
    assert(scanner.depth > 0);

    scanner.cursor += 1;
    scanner.depth -= 1;
    scanner.state = .post_value;
    return kind;
}

fn readLiteral(scanner: *Scanner, comptime spelling: []const u8, kind: Kind) Error!Kind {
    const end = scanner.cursor + spelling.len;
    if (end > scanner.input.len) return error.BadPayload;
    if (!std.mem.eql(u8, scanner.input[scanner.cursor..end], spelling)) return error.BadPayload;

    scanner.cursor = end;
    scanner.state = .post_value;
    return kind;
}

/// Assumes the opening quote is already behind the cursor.
fn readString(scanner: *Scanner) Error!void {
    const start = scanner.cursor;
    scanner.escaped = false;

    // The search reports what it passed, so a string spelled in ASCII is known to be UTF-8
    // by the time its closing quote is reached.
    var ascii = true;

    while (scanner.cursor < scanner.input.len) {
        // Everything up to the next byte JSON spells differently stands for itself, so the
        // whole run of it is passed over in one search.
        const rest = scanner.input[scanner.cursor..];
        const found = scan.findEscape(scan.payload_widths, rest);
        if (found.at == rest.len) break;

        scanner.cursor += found.at;
        if (!found.ascii) ascii = false;

        const character = scanner.input[scanner.cursor];
        assert(scan.escapes(character));

        switch (character) {
            '"' => {
                const text = scanner.input[start..scanner.cursor];

                // JSON is UTF-8, and a walk hands these bytes on as text, so what is not
                // UTF-8 is refused here and never reaches a caller.
                if (!ascii and !std.unicode.utf8ValidateSlice(text)) return error.BadPayload;

                scanner.value = text;
                scanner.cursor += 1;
                return;
            },
            '\\' => {
                scanner.escaped = true;
                scanner.cursor += 1;
                try scanner.readEscape();
            },

            // A control character has to be spelled as an escape, so a raw one is a break.
            else => return error.BadPayload,
        }
    }

    return error.BadPayload;
}

fn readEscape(scanner: *Scanner) Error!void {
    const character = scanner.take() orelse return error.BadPayload;

    switch (character) {
        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {},
        'u' => {
            if (scanner.cursor + 4 > scanner.input.len) return error.BadPayload;
            const quad = scanner.input[scanner.cursor..][0..4];
            for (quad) |digit| {
                if (!std.ascii.isHex(digit)) return error.BadPayload;
            }

            // A surrogate half carries nothing a codepoint can hold, so a quad that could be
            // one is read the way the unescape reads it and held to the same pairing.
            if (quad[0] == 'd' or quad[0] == 'D') {
                var point: u21 = undefined;
                scanner.cursor = try readCodepoint(scanner.input, scanner.cursor, &point);
            } else scanner.cursor += 4;
        },
        else => return error.BadPayload,
    }
}

fn readNumber(scanner: *Scanner) Error!void {
    const start = scanner.cursor;

    if (scanner.peekByte() == '-') scanner.cursor += 1;

    const leading = try scanner.readDigits();
    if (leading > 1 and scanner.input[scanner.cursor - leading] == '0') return error.BadPayload;

    if (scanner.peekByte() == '.') {
        scanner.cursor += 1;
        _ = try scanner.readDigits();
    }

    if (scanner.peekByte()) |exponent| {
        if (exponent == 'e' or exponent == 'E') {
            scanner.cursor += 1;
            if (scanner.peekByte()) |sign| {
                if (sign == '+' or sign == '-') scanner.cursor += 1;
            }
            _ = try scanner.readDigits();
        }
    }

    scanner.value = scanner.input[start..scanner.cursor];
    assert(scanner.value.len > 0);
}

/// Answers how many ran, which is at least one.
fn readDigits(scanner: *Scanner) Error!usize {
    const start = scanner.cursor;
    while (scanner.cursor < scanner.input.len) : (scanner.cursor += 1) {
        if (!std.ascii.isDigit(scanner.input[scanner.cursor])) break;
    }

    const count = scanner.cursor - start;
    if (count == 0) return error.BadPayload;
    return count;
}

fn skipWhitespace(scanner: *Scanner) void {
    scanner.cursor = skipSpaceAt(scanner.input, scanner.cursor);
}

fn peekByte(scanner: *const Scanner) ?u8 {
    if (scanner.cursor == scanner.input.len) return null;
    return scanner.input[scanner.cursor];
}

fn take(scanner: *Scanner) ?u8 {
    const character = scanner.peekByte() orelse return null;
    scanner.cursor += 1;
    return character;
}

/// Writes the text a string stands for into `out`, answering the length it has whether or not
/// that much of it fit. A caller holding text to a capacity compares the two.
///
/// `raw` is what `value` held for a `.string`.
pub fn unescape(out: []u8, raw: []const u8) Error!usize {
    var written: usize = 0;
    var index: usize = 0;

    while (index < raw.len) {
        if (raw[index] != '\\') {
            const run = std.mem.indexOfScalarPos(u8, raw, index, '\\') orelse raw.len;
            written += put(out, written, raw[index..run]);
            index = run;
            continue;
        }

        index += 1;
        if (index == raw.len) return error.BadPayload;

        const spelled = raw[index];
        index += 1;

        const single: u8 = switch (spelled) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'b' => 0x08,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'u' => {
                var point: u21 = undefined;
                index = try readCodepoint(raw, index, &point);

                var encoded: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(point, &encoded) catch
                    return error.BadPayload;
                written += put(out, written, encoded[0..length]);
                continue;
            },
            else => return error.BadPayload,
        };

        written += put(out, written, &.{single});
    }

    return written;
}

/// Reads one `\u` escape and whatever low surrogate it needs, answering where it ended.
fn readCodepoint(raw: []const u8, start: usize, point: *u21) Error!usize {
    var index = start;
    const high = try readHex(raw, index);
    index += 4;

    if (high < 0xd800 or high > 0xdbff) {
        // A lone low surrogate stands for nothing a codepoint can carry.
        if (high >= 0xdc00 and high <= 0xdfff) return error.BadPayload;
        point.* = high;
        return index;
    }

    if (index + 2 > raw.len) return error.BadPayload;
    if (raw[index] != '\\' or raw[index + 1] != 'u') return error.BadPayload;
    index += 2;

    const low = try readHex(raw, index);
    index += 4;
    if (low < 0xdc00 or low > 0xdfff) return error.BadPayload;

    point.* = 0x10000 + ((high - 0xd800) << 10) + (low - 0xdc00);
    return index;
}

fn readHex(raw: []const u8, start: usize) Error!u21 {
    if (start + 4 > raw.len) return error.BadPayload;

    var point: u21 = 0;
    for (raw[start..][0..4]) |digit| {
        const value = std.fmt.charToDigit(digit, 16) catch return error.BadPayload;
        point = (point << 4) | value;
    }
    return point;
}

/// Copies what fits and answers what the whole of it measures.
fn put(out: []u8, written: usize, bytes: []const u8) usize {
    if (written < out.len) {
        const room = @min(bytes.len, out.len - written);
        @memcpy(out[written..][0..room], bytes[0..room]);
    }
    return bytes.len;
}
