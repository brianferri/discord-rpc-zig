const std = @import("std");

/// A deadline `count` milliseconds out, measured on a clock that runs while the machine is awake.
pub fn milliseconds(count: i64) std.Io.Timeout {
    std.debug.assert(count >= 0);
    return .{ .duration = .{ .raw = .fromMilliseconds(count), .clock = .awake } };
}

test milliseconds {
    const short = milliseconds(250);
    try std.testing.expectEqual(std.Io.Clock.awake, short.duration.clock);
    try std.testing.expectEqual(@as(i64, 250), short.duration.raw.toMilliseconds());

    // Zero is a deadline already past, which is how a caller asks for whatever is ready now.
    try std.testing.expectEqual(@as(i64, 0), milliseconds(0).duration.raw.toMilliseconds());
}
