//! Registration of the `discord-<application_id>://` protocol handler.
//!
//! Discord launches a game from an invite by opening that URL. This is separate from the
//! RPC connection; a game whose installer claims the scheme never needs it.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const platform = switch (@import("builtin").target.os.tag) {
    .linux, .freebsd, .netbsd, .openbsd => @import("linux.zig"),
    .macos => @import("macos.zig"),
    .windows => @import("windows.zig"),
    else => |os| @compileError("Unsupported OS: " ++ @tagName(os)),
};

/// One set for every target, so a caller's switch stays exhaustive wherever it is built.
pub const Error = error{
    NoHomeDirectory,
    NoExecutablePath,
    NameTooLong,
    /// The registry held a value that is not the text it is typed as.
    InvalidUtf8,
    /// The entry reached the system, which then declined to record it.
    RegistrationFailed,
    /// `xdg-mime` is what makes the entry the default handler.
    MimeToolUnavailable,
    RegistryUnavailable,
    NoSteamInstallation,
    NoBundle,
    CoreServicesUnavailable,
};

pub const scheme_prefix = "discord-";

/// Room for the scheme and any application id Discord issues.
pub const scheme_bytes: u32 = 128;

pub const steam_url_prefix = "steam://rungameid/";

/// A null command registers the running executable.
pub const handler = platform.handler;

/// Registers a handler that launches the game through Steam.
pub fn steamGame(
    io: Io,
    environ: *std.process.Environ.Map,
    application_id: []const u8,
    steam_id: []const u8,
) Error!void {
    assert(application_id.len > 0);
    assert(steam_id.len > 0);

    var command_storage: [platform.steam_command_bytes]u8 = undefined;
    const command = try platform.steamCommand(&command_storage, steam_id);
    assert(command.len > steam_id.len);

    return handler(io, environ, application_id, command);
}

test "a steam command carries the game's url" {
    var storage: [platform.steam_command_bytes]u8 = undefined;
    const command = platform.steamCommand(&storage, "9001") catch |err| switch (err) {
        // Windows builds the command around an installed Steam, which need not be present.
        error.NoSteamInstallation, error.RegistryUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };

    try std.testing.expect(std.mem.endsWith(u8, command, steam_url_prefix ++ "9001"));
}

test {
    _ = platform;

    // Referencing the entry points forces their bodies to be analysed; nothing
    // else in the tests reaches registration.
    _ = &handler;
    _ = &steamGame;
}
