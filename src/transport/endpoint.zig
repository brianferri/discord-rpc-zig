//! How Discord names its local endpoints, and what reaching one can fail with.

const std = @import("std");
const Io = std.Io;

pub const OpenError = error{ NoEndpoint, NameTooLong } || Io.Cancelable;

/// Any failure short of cancelation leaves the connection unusable.
pub const Error = error{ConnectionClosed} || Io.Cancelable;

/// One per running client: stable, PTB and Canary can serve at once.
pub const count: u32 = 10;

pub const name_prefix = "discord-ipc-";

pub const pipe_path_prefix = "\\??\\pipe\\" ++ name_prefix;

pub const family: enum { socket, pipe } = switch (@import("builtin").target.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd => .socket,
    .windows => .pipe,
    else => |os| @compileError("Unsupported OS: " ++ @tagName(os)),
};

pub fn digit(number: u32) u8 {
    std.debug.assert(number < count);
    std.debug.assert(count <= 10);
    return '0' + @as(u8, @intCast(number));
}

test digit {
    try std.testing.expectEqual(@as(u8, '0'), digit(0));
    try std.testing.expectEqual(@as(u8, '9'), digit(count - 1));
}
