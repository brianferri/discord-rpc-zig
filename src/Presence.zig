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

/// Discord's `type` on the activity, which is how it phrases the activity in the member list.
///
/// The documentation limits `SET_ACTIVITY` to playing, listening, watching and competing, and
/// the client has taken the other two before the documentation named them. Left open, since
/// Discord numbers these itself and adds to them.
pub const ActivityType = enum(u8) {
    playing = 0,
    streaming = 1,
    listening = 2,
    watching = 3,
    custom = 4,
    competing = 5,
    _,
};

/// Discord's `status_display_type`: which of the fields below feeds the status message.
pub const StatusDisplayType = enum(u8) {
    /// The application's own name.
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
activity_type: ActivityType = .playing,
status_display_type: StatusDisplayType = .name,
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
