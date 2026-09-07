//! The byte-level searches JSON rests on, answered a lane at a time.
//!
//! Reading and writing ask the same two questions of a run of bytes: where the next byte JSON
//! spells differently is, and whether the run is ASCII. Both are here so the tokeniser and the
//! writer put the same answer on the same bytes.

const std = @import("std");
const assert = std.debug.assert;

/// The widest group a search compares at once, sized for Discord's strings, which
/// run from a few bytes to a few dozen.
pub const lanes = 16;

const Lane = @Vector(lanes, u8);
const Mask = @Int(.unsigned, lanes);

comptime {
    assert(@bitSizeOf(Mask) == lanes);
}

/// Whether JSON spells `character` as something other than itself. Inside a string these are
/// the bytes that end a run of text: the two with an escape of their own, and the control
/// characters, which carry no literal spelling at all.
///
/// A group of one holds the rule, so a byte and a lane are judged by the same comparison.
pub fn escapes(character: u8) bool {
    return escapeInGroup(1, .{character}) != null;
}

/// Group sizes for a run that reaches past any one group, which is what a whole payload is.
pub const payload_widths: []const usize = &.{lanes};

/// Group sizes for a run that is one field, which is often shorter than a lane. Narrowing
/// after the lane is what keeps a short field off the byte-at-a-time walk.
pub const field_widths: []const usize = &.{ lanes, lanes / 2 };

/// Where a search stopped, and what it saw on the way.
pub const Run = struct {
    /// The offset of the first byte `escapes` claims, or the length of the run when it holds
    /// none.
    at: usize,
    /// Whether every byte the search passed stands for itself as a codepoint. A run read as
    /// carrying more than ASCII costs its caller a walk, so overstating it is safe.
    ascii: bool,
};

/// Finds the first byte `escapes` claims, answering as well whether what came before it was
/// ASCII. A tokeniser wants both of every string it takes, and one pass over the bytes gives
/// them together.
///
/// `widths` names the group sizes to search in, widest first. A size the run never reaches
/// still costs a branch on every call, so each caller names the sizes its own runs fill.
pub fn findEscape(comptime widths: []const usize, text: []const u8) Run {
    comptime assert(widths.len > 0);

    var index: usize = 0;
    var wide = false;

    inline for (widths) |width| {
        comptime assert(width > 0);
        const Group = @Vector(width, u8);

        while (index + width <= text.len) : (index += width) {
            const group: Group = text[index..][0..width].*;

            // The whole group folds in, including whatever sits past an escape it holds.
            const high: @Int(.unsigned, width) = @bitCast(group >= @as(Group, @splat(0x80)));
            if (high != 0) wide = true;

            if (escapeInGroup(width, group)) |found| {
                return .{ .at = index + found, .ascii = !wide };
            }
        }
    }

    while (index < text.len) : (index += 1) {
        if (text[index] >= 0x80) wide = true;
        if (escapes(text[index])) return .{ .at = index, .ascii = !wide };
    }
    return .{ .at = text.len, .ascii = !wide };
}

/// The offset within one group of the first byte `escapes` claims.
fn escapeInGroup(comptime width: usize, group: @Vector(width, u8)) ?usize {
    const Group = @Vector(width, u8);
    const claimed = @as(@Vector(width, bool), group < @as(Group, @splat(0x20))) |
        (group == @as(Group, @splat('"'))) |
        (group == @as(Group, @splat('\\')));

    const found: @Int(.unsigned, width) = @bitCast(claimed);
    if (found == 0) return null;
    return @ctz(found);
}

/// Whether the run is printable ASCII that a string spells as itself. Text this answers true
/// for occupies exactly its own length once written, which is what lets a caller size a buffer
/// from a capacity alone.
pub fn plain(text: []const u8) bool {
    var index: usize = 0;
    var refused: Mask = 0;

    while (index + lanes <= text.len) : (index += lanes) {
        refused |= refusedInGroup(lanes, text[index..][0..lanes].*);
    }
    if (index > 0) {
        // The closing read overlaps the one before it, so a run of any length costs a single
        // read past the whole lanes it holds.
        assert(text.len >= lanes);
        refused |= refusedInGroup(lanes, text[text.len - lanes ..][0..lanes].*);
        return refused == 0;
    }

    while (index < text.len) : (index += 1) {
        if (refusedInGroup(1, .{text[index]}) != 0) return false;
    }
    return true;
}

/// One bit per byte the run may not carry, so a whole group is judged in one fold.
fn refusedInGroup(comptime width: usize, group: @Vector(width, u8)) @Int(.unsigned, width) {
    const Group = @Vector(width, u8);
    const refused = @as(@Vector(width, bool), group <= @as(Group, @splat(0x20))) |
        (group >= @as(Group, @splat(0x7f))) |
        (group == @as(Group, @splat('"'))) |
        (group == @as(Group, @splat('\\')));

    return @bitCast(refused);
}

/// Whether every byte stands for itself as a codepoint. Text this answers true for is valid
/// UTF-8 already, which is what lets `validUtf8` settle the common case without a walk.
pub fn ascii(text: []const u8) bool {
    var index: usize = 0;

    var wide: Lane = @splat(0);
    while (index + lanes <= text.len) : (index += lanes) {
        wide |= @as(Lane, text[index..][0..lanes].*);
    }
    if (index > 0) {
        // The closing read overlaps the one before it, so a run of any length costs a single
        // read past the whole lanes it holds.
        assert(text.len >= lanes);
        wide |= @as(Lane, text[text.len - lanes ..][0..lanes].*);
        return @reduce(.Or, wide) & 0x80 == 0;
    }

    // A run too narrow for a lane folds a word at a time, and the same read closes it.
    const word = @sizeOf(usize);
    const high: usize = @bitCast(@as([word]u8, @splat(0x80)));
    var narrow: usize = 0;

    if (text.len >= word) {
        while (index + word <= text.len) : (index += word) {
            narrow |= @as(usize, @bitCast(text[index..][0..word].*));
        }
        narrow |= @as(usize, @bitCast(text[text.len - word ..][0..word].*));
    } else {
        assert(text.len < word);
        for (text) |character| narrow |= character;
    }

    return narrow & high == 0;
}

/// Text handed on as text must be UTF-8. The general validator opens with a scan of its own
/// and falls to a byte-at-a-time walk over anything shorter than one chunk of it, so the run
/// is held to ASCII first and only what carries a high bit is walked.
pub fn validUtf8(text: []const u8) bool {
    if (ascii(text)) return true;
    return std.unicode.utf8ValidateSlice(text);
}

test escapes {
    try std.testing.expect(escapes('"'));
    try std.testing.expect(escapes('\\'));
    try std.testing.expect(escapes(0x00));
    try std.testing.expect(escapes(0x1f));

    try std.testing.expect(!escapes(0x20));
    try std.testing.expect(!escapes('a'));
    try std.testing.expect(!escapes(0xff));
}

// A lane covers a fixed width, so a byte falling on either side of one is where an off-by-one
// would show. This walks the byte across three lanes' worth of text, and past the end.
test "an escape is found wherever it falls against the lane width" {
    var text: [lanes * 3]u8 = undefined;

    for (0..text.len) |at| {
        for (1..text.len + 1) |length| {
            text = @splat('a');
            text[at] = '"';

            const want = if (at < length) at else length;
            inline for (.{ payload_widths, field_widths }) |widths| {
                const found = findEscape(widths, text[0..length]);
                std.testing.expectEqual(want, found.at) catch |err| {
                    std.debug.print("at {d} of {d}, widths {any}\n", .{ at, length, widths });
                    return err;
                };
            }
        }
    }
}

test ascii {
    try std.testing.expect(ascii(""));
    try std.testing.expect(ascii("a"));
    try std.testing.expect(ascii("a reasonably long piece of plain text that fills a lane"));

    // The high bit is found wherever it falls, so it is walked across the widths too.
    var text: [lanes * 3]u8 = undefined;
    for (0..text.len) |at| {
        text = @splat('a');
        text[at] = 0x80;
        try std.testing.expect(!ascii(&text));
        try std.testing.expect(ascii(text[0..at]));
    }
}

test plain {
    try std.testing.expect(plain(""));
    try std.testing.expect(plain("https://example.invalid/one"));
    try std.testing.expect(plain("~!@#$%^&*()_+"));

    // Each refused byte is walked across the widths, since a lane covers a fixed run.
    var text: [lanes * 3]u8 = undefined;
    for ([_]u8{ 0x00, 0x20, '"', '\\', 0x7f, 0xff }) |refused| {
        for (0..text.len) |at| {
            text = @splat('a');
            text[at] = refused;
            try std.testing.expect(!plain(&text));
            try std.testing.expect(plain(text[0..at]));
        }
    }
}

// The ASCII answer rides along with the search, so it is held to the same bytes the search
// passed. Overstating it is safe; understating it would hand out text nothing validated.
test "a search reports ASCII for exactly what it passed" {
    try std.testing.expect(findEscape(payload_widths, "plain text\"rest").ascii);
    try std.testing.expect(!findEscape(payload_widths, "caf\u{e9}\"rest").ascii);

    // A high bit past the escape may be folded in, so the answer is allowed to be false
    // there; what it may never do is report ASCII over a byte that is not.
    var text: [lanes * 3]u8 = undefined;
    for (0..text.len) |at| {
        text = @splat('a');
        text[at] = 0xc3;

        inline for (.{ payload_widths, field_widths }) |widths| {
            const found = findEscape(widths, &text);
            try std.testing.expectEqual(text.len, found.at);
            try std.testing.expect(!found.ascii);
        }
    }
}

test validUtf8 {
    try std.testing.expect(validUtf8("plain"));
    try std.testing.expect(validUtf8("caf\u{e9}"));
    try std.testing.expect(validUtf8("\u{1f600} and more"));

    try std.testing.expect(!validUtf8(&.{0x80}));
    try std.testing.expect(!validUtf8("a\xc3"));
    try std.testing.expect(!validUtf8("\xed\xa0\x80"));
}

// The two answer the same question, and the fast path must not widen what the general one takes.
test "every byte agrees with the validator std ships" {
    var text: [3]u8 = undefined;

    for (0..256) |first| {
        text[0] = @intCast(first);
        for (0..256) |second| {
            text[1] = @intCast(second);
            try std.testing.expectEqual(
                std.unicode.utf8ValidateSlice(text[0..2]),
                validUtf8(text[0..2]),
            );
        }
    }
}
