//! A desktop entry under `~/.local/share/applications`, plus an `xdg-mime` default so
//! `xdg-open discord-<id>://...` reaches it.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Environ = std.process.Environ;

const protocol = @import("root.zig");

pub const Error = protocol.Error;
const scheme_prefix = protocol.scheme_prefix;
const scheme_bytes = protocol.scheme_bytes;
const steam_url_prefix = protocol.steam_url_prefix;

/// `%u` is what tells the desktop entry to pass the invite URL through to the game.
const desktop_entry =
    \\[Desktop Entry]
    \\Name=Game {s}
    \\Exec={s} %u
    \\Type=Application
    \\NoDisplay=true
    \\Categories=Discord;Games;
    \\MimeType=x-scheme-handler/discord-{s};
    \\
;

/// The mime type an `xdg-open` of the scheme resolves through.
const mime_prefix = "x-scheme-handler/" ++ scheme_prefix;

// The entry declares the type and `setMimeDefault` claims it; the two must agree.
comptime {
    assert(std.mem.indexOf(u8, desktop_entry, mime_prefix) != null);
}

pub fn handler(
    io: Io,
    environ: *Environ.Map,
    application_id: []const u8,
    command: ?[]const u8,
) Error!void {
    assert(application_id.len > 0);

    const home = environ.get("HOME") orelse "";
    if (home.len == 0) return error.NoHomeDirectory;

    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = command orelse blk: {
        const length = std.process.executablePath(io, &executable_buffer) catch
            return error.NoExecutablePath;
        break :blk executable_buffer[0..length];
    };

    var entry_buffer: [2048]u8 = undefined;
    const entry = std.fmt.bufPrint(&entry_buffer, desktop_entry, .{
        application_id,
        executable,
        application_id,
    }) catch return error.NameTooLong;

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = std.fmt.bufPrint(&path_buffer, "{s}/.local/share/applications", .{home}) catch
        return error.NameTooLong;

    var applications = Io.Dir.cwd().createDirPathOpen(io, directory, .{}) catch
        return error.RegistrationFailed;
    defer applications.close(io);

    var name_buffer: [256]u8 = undefined;
    const name = std.fmt.bufPrint(
        &name_buffer,
        scheme_prefix ++ "{s}.desktop",
        .{application_id},
    ) catch return error.NameTooLong;

    applications.writeFile(io, .{ .sub_path = name, .data = entry }) catch
        return error.RegistrationFailed;

    try setMimeDefault(io, environ, application_id, name);
}

pub const steam_command_bytes = 256;

/// The entry runs a command, so the URL is wrapped in `xdg-open`.
pub fn steamCommand(out: []u8, steam_id: []const u8) Error![]u8 {
    assert(steam_id.len > 0);

    const command = std.fmt.bufPrint(
        out,
        "xdg-open " ++ steam_url_prefix ++ "{s}",
        .{steam_id},
    ) catch return error.NameTooLong;

    assert(command.len > steam_id.len);
    return command;
}

/// The entry declares the scheme; only the mime default makes `xdg-open` pick it.
fn setMimeDefault(
    io: Io,
    environ: *Environ.Map,
    application_id: []const u8,
    desktop_name: []const u8,
) Error!void {
    assert(desktop_name.len > 0);

    var scheme_buffer: [scheme_bytes]u8 = undefined;
    const scheme = std.fmt.bufPrint(
        &scheme_buffer,
        mime_prefix ++ "{s}",
        .{application_id},
    ) catch return error.NameTooLong;

    // Spawned; capturing its output would need an allocator.
    var child = std.process.spawn(io, .{
        .argv = &.{ "xdg-mime", "default", desktop_name, scheme },
        .environ_map = environ,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.MimeToolUnavailable;

    const term = child.wait(io) catch return error.MimeToolUnavailable;
    switch (term) {
        .exited => |status| if (status != 0) return error.MimeToolUnavailable,
        else => return error.MimeToolUnavailable,
    }
}
