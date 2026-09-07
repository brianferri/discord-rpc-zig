//! Inline string storage, so a record carrying one travels by value.

const std = @import("std");
const assert = std.debug.assert;

/// A fixed-capacity string. A value longer than the capacity is truncated.
pub fn Buffer(comptime capacity: u32) type {
    comptime assert(capacity > 0);

    return struct {
        bytes: [capacity]u8 = @splat(0),
        len: Length = 0,

        const Self = @This();

        pub const Length = if (capacity <= std.math.maxInt(u8))
            u8
        else if (capacity <= std.math.maxInt(u16))
            u16
        else
            u32;

        comptime {
            assert(capacity <= std.math.maxInt(Length));
        }

        pub const empty: Self = .{};

        pub const capacity_bytes: u32 = capacity;

        pub fn set(self: *Self, value: []const u8) void {
            self.clear();
            self.append(value);
        }

        pub fn append(self: *Self, value: []const u8) void {
            assert(self.len <= capacity);

            const room = capacity - self.len;
            const copied: Length = @intCast(@min(value.len, room));
            @memcpy(self.bytes[self.len..][0..copied], value[0..copied]);
            self.len += copied;

            assert(self.len <= capacity);
        }

        pub fn clear(self: *Self) void {
            assert(self.len <= capacity);
            self.len = 0;
            assert(self.len == 0);
        }

        pub fn slice(self: *const Self) []const u8 {
            assert(self.len <= capacity);
            return self.bytes[0..self.len];
        }
    };
}

test "a value longer than the capacity is truncated" {
    var buffer: Buffer(4) = .empty;

    buffer.set("ab");
    try std.testing.expectEqualStrings("ab", buffer.slice());

    buffer.set("abcdef");
    try std.testing.expectEqualStrings("abcd", buffer.slice());

    buffer.clear();
    try std.testing.expectEqualStrings("", buffer.slice());
}

test "the length field is no wider than the capacity needs" {
    try std.testing.expectEqual(u8, Buffer(1).Length);
    try std.testing.expectEqual(u8, Buffer(255).Length);
    try std.testing.expectEqual(u16, Buffer(256).Length);
    try std.testing.expectEqual(u16, Buffer(65535).Length);

    try std.testing.expectEqual(@as(usize, 25), @sizeOf(Buffer(24)));
    try std.testing.expectEqual(@as(usize, 1), @alignOf(Buffer(24)));
}

test "appending fills the remaining room and stops" {
    var buffer: Buffer(4) = .empty;

    buffer.append("ab");
    buffer.append("cd");
    try std.testing.expectEqualStrings("abcd", buffer.slice());

    buffer.append("ef");
    try std.testing.expectEqualStrings("abcd", buffer.slice());
}
