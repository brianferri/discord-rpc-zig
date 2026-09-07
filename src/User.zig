//! A Discord account as reported over RPC. A value longer than its field is truncated.

const std = @import("std");
const text = @import("text.zig");

const User = @This();

/// A snowflake is a 64-bit integer in decimal, so at most 20 digits.
const id_bytes = 24;
/// Discord caps a username at 32 characters, each up to 4 bytes of UTF-8.
const username_bytes = 32 * 4;
/// Four decimal digits, or the single "0" of an account migrated off discriminators.
const discriminator_bytes = 8;
/// An optional `a_` prefix for an animated avatar, then a 32-character hex digest.
const avatar_bytes = 64;

id: text.Buffer(id_bytes) = .empty,
username: text.Buffer(username_bytes) = .empty,
discriminator: text.Buffer(discriminator_bytes) = .empty,
avatar: text.Buffer(avatar_bytes) = .empty,

pub const empty: User = .{};

pub fn capacityOf(comptime field: []const u8) u32 {
    return @FieldType(User, field).capacity_bytes;
}

test "fields default to empty" {
    const user: User = .empty;
    try std.testing.expectEqualStrings("", user.id.slice());
    try std.testing.expectEqualStrings("", user.avatar.slice());
}

test "every capacity holds the longest value its field can carry" {
    var user: User = .empty;

    user.id.set("18446744073709551615");
    try std.testing.expectEqual(@as(u32, 20), user.id.len);

    const characters: [32][4]u8 = @splat("\u{10FFFF}".*);
    const widest_name: [username_bytes]u8 = @bitCast(characters);

    user.username.set(&widest_name);
    try std.testing.expectEqual(@as(u32, username_bytes), user.username.len);

    user.discriminator.set("4242");
    try std.testing.expectEqual(@as(u32, 4), user.discriminator.len);

    user.avatar.set("a_0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f");
    try std.testing.expectEqual(@as(u32, 34), user.avatar.len);
}
