//! Activity payload for the `SET_ACTIVITY` command. Discord truncates anything longer
//! than the byte limits noted here.

const std = @import("std");

const Presence = @This();

pub const max_text_bytes: u32 = 128;
pub const max_image_key_bytes: u32 = 32;
pub const max_button_label_bytes: u32 = 32;
pub const max_button_url_bytes: u32 = 512;
pub const max_url_bytes: u32 = 512;
pub const max_buttons: u32 = 2;

/// The schemes a presence link may open with, which are the ones Discord opens as web links.
/// A link is held to one of these and to a name behind it.
pub const url_schemes = [_][]const u8{ "http://", "https://" };

/// A link shown under the presence. The URL must carry a `url_schemes` scheme and only the
/// printable ASCII a URL may spell; anything else is `error.InvalidPresence`.
///
/// Sending buttons alongside any secret is answered by Discord with
/// `5005: secrets cannot currently be sent with buttons`, delivered as an `errored` event.
pub const Button = struct {
    label: []const u8,
    url: []const u8,
};

/// How Discord phrases the activity in the member list. `SET_ACTIVITY` takes these four.
pub const Kind = enum(u8) {
    playing = 0,
    listening = 2,
    watching = 3,
    competing = 5,
};

/// Which line the member list shows beside the activity.
pub const StatusDisplay = enum(u8) {
    name = 0,
    state = 1,
    details = 2,
};

state: ?[]const u8 = null, // max_text_bytes
details: ?[]const u8 = null, // max_text_bytes
/// Opened when the player taps the line above it. Held to `url_schemes` and `max_url_bytes`.
state_url: ?[]const u8 = null,
details_url: ?[]const u8 = null,
start_timestamp: ?i64 = null,
end_timestamp: ?i64 = null,
large_image_key: ?[]const u8 = null, // max_image_key_bytes
large_image_text: ?[]const u8 = null, // max_text_bytes
/// Opened when the player taps the image. Held to `url_schemes` and `max_url_bytes`.
large_image_url: ?[]const u8 = null,
small_image_key: ?[]const u8 = null, // max_image_key_bytes
small_image_text: ?[]const u8 = null, // max_text_bytes
small_image_url: ?[]const u8 = null,
party_id: ?[]const u8 = null, // max_text_bytes
/// Zero in either reports no size at all; the current size must be within the maximum.
party_size: u32 = 0,
party_max: u32 = 0,
party_privacy: Privacy = .private,
match_secret: ?[]const u8 = null, // max_text_bytes
join_secret: ?[]const u8 = null, // max_text_bytes
spectate_secret: ?[]const u8 = null, // max_text_bytes
instance: bool = false,
kind: Kind = .playing,
status_display: StatusDisplay = .name,
/// At most `max_buttons`. Borrowed only for the length of the call that carries them.
buttons: []const Button = &.{},

pub const Privacy = enum(u8) {
    private = 0,
    public = 1,
};

test "an unset presence carries nothing" {
    const presence: Presence = .{};
    try std.testing.expect(presence.state == null);
    try std.testing.expect(presence.start_timestamp == null);
    try std.testing.expectEqual(@as(u32, 0), presence.party_size);
    try std.testing.expectEqual(Privacy.private, presence.party_privacy);
}
