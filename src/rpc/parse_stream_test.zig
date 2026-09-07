//! A payload that crossed an endpoint against the same bytes in memory.
//!
//! The walk reads a frame whole, so what the wire delivers must equal what was sent and stop
//! exactly where the frame does. A mock would only prove the mock, so these bytes cross
//! a socket or a pipe.

const std = @import("std");
const Io = std.Io;

const parse = @import("parse.zig");
const transport = @import("../transport/root.zig");
const Pair = @import("../transport/server.zig").Pair;

const payloads = [_][]const u8{
    \\{"cmd":"DISPATCH","evt":"READY","data":{"v":1,"config":{"api_endpoint":"//discord.com/api"},"user":{"id":"222222222222222222","username":"example","discriminator":"4242","avatar":"a_0f0","bot":false}}}
    ,
    \\{"cmd":"DISPATCH","data":{"secret":"abcdef01"},"evt":"ACTIVITY_JOIN"}
    ,
    \\{"nonce":"42","evt":"ERROR","data":{"code":4000,"message":"Invalid activity"}}
    ,
    \\{"code":1000,"message":"closing"}
    ,
    \\{"code":1,"message":"line\nbreak \u0041nd \"quotes\""}
    ,
    \\{"cmd":{"nested":true},"evt":["a"],"code":"not a number","data":42}
    ,
    \\{"evt":"ACTIVITY_JOIN","extra":{"a":{"b":{"c":{"d":[[[["deep"]]]]}}}},"data":{"secret":"ok"}}
    ,
    \\{"data":{"user":{"id":"111","username":"trusted"},"user":[]}}
    ,
    \\{"data":{"secret":"legit"},"data":{"code":4000,"message":"boom"}}
    ,
    \\{"data":{"code":4000},"code":10}
    ,
    \\{"cmd":{"nonce":1,"evt":"ERROR","code":4000,"message":"boom"}}
    ,
    \\{"nonce":null,"evt":"ERROR","code":4000}
    ,
    \\{"a_key_far_longer_than_any_member_this_protocol_names":1,"evt":"ACTIVITY_JOIN"}
    ,
    \\{"data":{"user":{"id":"11111111111111111111111\u00e9"}}}
    ,
    \\{}
    ,
    // Refused by both, so the streamed walk has to drain what it did not read.
    \\{"code":2147483648,"message":"boom"}
    ,
    \\{"cmd":"DISPATCH"
    ,
    \\{"code":1} trailing
    ,
};

/// The bytes off the endpoint walk to the same frame as the bytes in hand, and the sentinel
/// behind them is still there to be read.
fn expectAgreement(io: Io, pair: *Pair, payload: []const u8) !void {
    const direct = parse.frame(payload);

    try transport.writeAll(&pair.peer, io, payload, .none);
    try transport.writeAll(&pair.peer, io, "!", .none);

    var buffer: [4 * 1024]u8 = undefined;
    std.debug.assert(payload.len > 0);
    std.debug.assert(payload.len <= buffer.len);
    const arrived = buffer[0..payload.len];
    try transport.readAll(&pair.transport, io, arrived, .none);
    try std.testing.expectEqualStrings(payload, arrived);

    const wire = parse.frame(arrived);

    if (direct) |expected| {
        try std.testing.expect(std.meta.eql(expected, try wire));
    } else |expected_error| {
        try std.testing.expectError(expected_error, wire);
    }

    // The frame's own bytes are drawn off before the sentinel behind them can be read.
    var sentinel: [1]u8 = undefined;
    try transport.readAll(&pair.transport, io, &sentinel, .none);
    try std.testing.expectEqualStrings("!", &sentinel);
}

test "a payload off the endpoint walks to the same frame as the bytes in hand" {
    const io = std.testing.io;

    var pair: Pair = undefined;
    try pair.open(io, std.testing.allocator);
    defer pair.close(io);
    defer pair.transport.close(io);

    for (payloads) |payload| try expectAgreement(io, &pair, payload);
}

test "a run of frames leaves the endpoint positioned for the next one" {
    const io = std.testing.io;

    var pair: Pair = undefined;
    try pair.open(io, std.testing.allocator);
    defer pair.close(io);
    defer pair.transport.close(io);

    // Repeated, so a frame that read a byte too many or too few shows up on the one after.
    for (0..3) |_| {
        for (payloads) |payload| try expectAgreement(io, &pair, payload);
    }
}

// A skipped value is held to the payload it sits in, which `Connection` asserts is no wider
// than `max_value_bytes`. A value read into a field is counted as it is gathered.
test "a value too wide for the field it is read into is refused" {
    const gpa = std.testing.allocator;

    for ([_]usize{ parse.max_value_bytes + 1, parse.max_value_bytes - 512 }) |length| {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(gpa);
        try payload.appendSlice(gpa, "{\"message\":\"");
        try payload.appendNTimes(gpa, 'a', length);
        try payload.appendSlice(gpa, "\",\"code\":7}");

        const walked = parse.frame(payload.items);

        if (length > parse.max_value_bytes) {
            try std.testing.expectError(error.BadPayload, walked);
        } else {
            const answer = try walked;
            try std.testing.expectEqual(@as(i32, 7), answer.code);
        }
    }
}
