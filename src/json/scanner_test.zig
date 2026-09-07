//! The scanner is held to the one `std` ships: on the same input the two agree on every token
//! and on whether the input was JSON at all.

const std = @import("std");
const Scanner = @import("Scanner.zig");

/// Every token, as a shape the two scanners can be compared through.
const Step = union(enum) {
    object_begin,
    object_end,
    array_begin,
    array_end,
    string: []const u8,
    number: []const u8,
    true,
    false,
    null,
};

/// Walks with this scanner, unescaping each string so the two are compared on their text.
fn ours(input: []const u8, steps: *std.ArrayList(Step), gpa: std.mem.Allocator) !void {
    var scanner: Scanner = .init(input);

    while (true) {
        const kind = try scanner.next();
        switch (kind) {
            .end_of_document => return,
            .object_begin => try steps.append(gpa, .object_begin),
            .object_end => try steps.append(gpa, .object_end),
            .array_begin => try steps.append(gpa, .array_begin),
            .array_end => try steps.append(gpa, .array_end),
            .true => try steps.append(gpa, .true),
            .false => try steps.append(gpa, .false),
            .null => try steps.append(gpa, .null),
            .number => try steps.append(gpa, .{ .number = try gpa.dupe(u8, scanner.value) }),
            .string => {
                const length = try Scanner.unescape(&.{}, scanner.value);
                const text = try gpa.alloc(u8, length);
                const written = try Scanner.unescape(text, scanner.value);
                std.debug.assert(written == length);
                try steps.append(gpa, .{ .string = text });
            },
        }
    }
}

/// The same walk through `std.json`, which hands an escaped string back in pieces even when
/// the whole input is in front of it. They are gathered here so the two are compared on text.
fn theirs(input: []const u8, steps: *std.ArrayList(Step), gpa: std.mem.Allocator) !void {
    var scanner: std.json.Scanner = .initCompleteInput(gpa, input);
    defer scanner.deinit();

    var gathered: std.ArrayList(u8) = .empty;

    while (true) {
        const token = try scanner.next();
        switch (token) {
            .end_of_document => return,
            .object_begin => try steps.append(gpa, .object_begin),
            .object_end => try steps.append(gpa, .object_end),
            .array_begin => try steps.append(gpa, .array_begin),
            .array_end => try steps.append(gpa, .array_end),
            .true => try steps.append(gpa, .true),
            .false => try steps.append(gpa, .false),
            .null => try steps.append(gpa, .null),

            .partial_string => |piece| try gathered.appendSlice(gpa, piece),
            .partial_string_escaped_1 => |piece| try gathered.appendSlice(gpa, &piece),
            .partial_string_escaped_2 => |piece| try gathered.appendSlice(gpa, &piece),
            .partial_string_escaped_3 => |piece| try gathered.appendSlice(gpa, &piece),
            .partial_string_escaped_4 => |piece| try gathered.appendSlice(gpa, &piece),
            .partial_number => |piece| try gathered.appendSlice(gpa, piece),

            .number => |text| {
                try gathered.appendSlice(gpa, text);
                try steps.append(gpa, .{ .number = try gathered.toOwnedSlice(gpa) });
            },
            .string => |text| {
                try gathered.appendSlice(gpa, text);
                try steps.append(gpa, .{ .string = try gathered.toOwnedSlice(gpa) });
            },
            else => return error.Unsupported,
        }
    }
}

/// Holds the two scanners to the same answer over the whole input. A document one refuses is
/// one the other must refuse, though which token each stops at is its own business.
pub fn expectSame(input: []const u8) !void {
    const gpa = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const room = arena.allocator();

    var mine: std.ArrayList(Step) = .empty;
    var yours: std.ArrayList(Step) = .empty;

    const my_result = ours(input, &mine, room);
    const your_result = theirs(input, &yours, room);

    // A payload one refuses is a payload the other must refuse.
    if (std.meta.isError(your_result)) {
        try std.testing.expect(std.meta.isError(my_result));
        return;
    }
    try my_result;

    try std.testing.expectEqual(yours.items.len, mine.items.len);
    for (yours.items, mine.items) |want, got| {
        try std.testing.expectEqual(@as(std.meta.Tag(Step), want), @as(std.meta.Tag(Step), got));
        switch (want) {
            .string => |text| try std.testing.expectEqualStrings(text, got.string),
            .number => |text| try std.testing.expectEqualStrings(text, got.number),
            else => {},
        }
    }
}

test "the two scanners agree on what a frame carries" {
    for ([_][]const u8{
        \\{"cmd":"DISPATCH","evt":"READY","data":{"v":1,"user":{"id":"5010","username":"bio"}}}
        ,
        \\{"a":[1,2,3],"b":{"c":{"d":"e"}},"f":true,"g":null,"h":-12.5e3,"i":""}
        ,
        \\{"escaped":"a\"b\\c\nd\te\u0001f\u001fg"}
        ,
        \\{"unicode":"caf\u00e9 \ud83d\ude00 done"}
        ,
        \\[]
        ,
        \\{}
        ,
        \\   {  "spaced"  :  [ 1 , 2 ]  }
        ,
        \\0
        ,
        \\"bare"
        ,
        \\{"deep":{"a":{"b":{"c":{"d":[[[["end"]]]]}}}}}
        ,
    }) |input| {
        expectSame(input) catch |err| {
            std.debug.print("disagreed on: {s}\n", .{input});
            return err;
        };
    }
}

test "the two scanners agree on what is not JSON" {
    for ([_][]const u8{
        \\{"unterminated":"
        ,
        \\{"trailing":1,}
        ,
        \\[1,]
        ,
        \\{"missing colon" 1}
        ,
        \\{"two":1 "values":2}
        ,
        \\{]
        ,
        \\[}
        ,
        \\01
        ,
        \\-
        ,
        \\1.
        ,
        \\1e
        ,
        \\tru
        ,
        \\{"raw control":"a
        ,
        \\{"bad escape":"a\qb"}
        ,
        \\{"short unicode":"a\u12"}
        ,
        \\{"lone high":"\ud83d"}
        ,
        \\{"lone low":"\udc00"}
        ,
        \\{"unpaired":"\ud83dx"}
        ,
        \\{} trailing
        ,
        \\
        ,
    }) |input| {
        expectSame(input) catch |err| {
            std.debug.print("disagreed on: {s}\n", .{input});
            return err;
        };
    }
}

test "nesting past the depth a scanner carries is refused" {
    const gpa = std.testing.allocator;

    const deep = try gpa.alloc(u8, (Scanner.max_depth + 1) * 2);
    defer gpa.free(deep);

    @memset(deep[0 .. Scanner.max_depth + 1], '[');
    @memset(deep[Scanner.max_depth + 1 ..], ']');

    var scanner: Scanner = .init(deep);
    while (true) {
        const kind = scanner.next() catch |err| {
            try std.testing.expectEqual(error.BadPayload, err);
            return;
        };
        if (kind == .end_of_document) break;
    }
    return error.TestExpectedRefusal;
}

test "a value is passed over whole" {
    var scanner: Scanner = .init(
        \\{"skip":{"a":[1,2,{"b":"c"}]},"keep":"here"}
    );

    try std.testing.expectEqual(Scanner.Kind.object_begin, try scanner.next());
    try std.testing.expectEqual(Scanner.Kind.string, try scanner.next());
    try std.testing.expectEqualStrings("skip", scanner.value);

    try scanner.skipValue();

    try std.testing.expectEqual(Scanner.Kind.string, try scanner.next());
    try std.testing.expectEqualStrings("keep", scanner.value);
    try std.testing.expectEqual(Scanner.Kind.string, try scanner.next());
    try std.testing.expectEqualStrings("here", scanner.value);
}

test "unescape answers the length it needs whatever room it was given" {
    const raw = "a\\\"b\\u00e9c";

    const needed = try Scanner.unescape(&.{}, raw);
    try std.testing.expectEqual(@as(usize, 6), needed);

    var room: [6]u8 = undefined;
    try std.testing.expectEqual(needed, try Scanner.unescape(&room, raw));
    try std.testing.expectEqualStrings("a\"b\u{e9}c", &room);

    // A caller holding text to a capacity sees the whole length and keeps what fits.
    var narrow: [3]u8 = undefined;
    try std.testing.expectEqual(needed, try Scanner.unescape(&narrow, raw));
    try std.testing.expectEqualStrings("a\"b", &narrow);
}
