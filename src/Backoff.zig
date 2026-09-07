//! Randomised exponential backoff between reconnection attempts.

const std = @import("std");
const assert = std.debug.assert;

const Backoff = @This();

min_ms: i64,
max_ms: i64,
current_ms: i64,
random: std.Random.DefaultPrng,

pub fn init(min_ms: i64, max_ms: i64, seed: u64) Backoff {
    assert(min_ms > 0);
    assert(max_ms >= min_ms);
    return .{
        .min_ms = min_ms,
        .max_ms = max_ms,
        .current_ms = min_ms,
        .random = .init(seed),
    };
}

pub fn reset(backoff: *Backoff) void {
    assert(backoff.current_ms >= backoff.min_ms);
    backoff.current_ms = backoff.min_ms;
    assert(backoff.current_ms == backoff.min_ms);
}

/// A delay drawn uniformly from `[min_ms, current_ms]`, where the bound doubles each call.
pub fn nextDelay(backoff: *Backoff) i64 {
    assert(backoff.current_ms >= backoff.min_ms);
    assert(backoff.current_ms <= backoff.max_ms);

    const delay = backoff.random.random().intRangeAtMost(i64, backoff.min_ms, backoff.current_ms);
    backoff.current_ms = @min(backoff.current_ms *| 2, backoff.max_ms);

    assert(delay >= backoff.min_ms);
    assert(delay <= backoff.max_ms);
    assert(backoff.current_ms <= backoff.max_ms);
    return delay;
}

test "delay grows to the ceiling and resets to the floor" {
    var backoff: Backoff = .init(500, 60 * 1000, 0);
    try std.testing.expectEqual(@as(i64, 500), backoff.current_ms);

    var attempt: u32 = 0;
    while (attempt < 64) : (attempt += 1) {
        const delay = backoff.nextDelay();
        try std.testing.expect(delay >= backoff.min_ms);
        try std.testing.expect(delay <= backoff.max_ms);
    }
    try std.testing.expectEqual(@as(i64, 60 * 1000), backoff.current_ms);

    backoff.reset();
    try std.testing.expectEqual(@as(i64, 500), backoff.current_ms);
}

test "the delay still spreads once the climb has saturated" {
    var first: Backoff = .init(500, 60 * 1000, 1);
    var second: Backoff = .init(500, 60 * 1000, 0xdeadbeef);

    var climb: u32 = 0;
    while (climb < 64) : (climb += 1) {
        _ = first.nextDelay();
        _ = second.nextDelay();
    }
    try std.testing.expectEqual(first.max_ms, first.current_ms);
    try std.testing.expectEqual(second.max_ms, second.current_ms);

    var differed: u32 = 0;
    var attempt: u32 = 0;
    while (attempt < 32) : (attempt += 1) {
        if (first.nextDelay() != second.nextDelay()) differed += 1;
    }
    try std.testing.expect(differed > 24);
}
