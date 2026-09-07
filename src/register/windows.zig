//! `HKEY_CURRENT_USER\Software\Classes\discord-<id>`, written through ntdll.
//!
//! The current user's hive is used because it needs no elevation, which a game being
//! launched by a player cannot ask for.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const windows = std.os.windows;

const Environ = std.process.Environ;

const protocol = @import("root.zig");

pub const Error = protocol.Error;
const scheme_prefix = protocol.scheme_prefix;
const scheme_bytes = protocol.scheme_bytes;
const steam_url_prefix = protocol.steam_url_prefix;

const max_path_wide = windows.PATH_MAX_WIDE;
const key_write = windows.ACCESS_MASK.Specific.Key.WRITE;
const key_read = windows.ACCESS_MASK.Specific.Key.READ;

extern "ntdll" fn NtCreateKey(
    KeyHandle: *windows.HANDLE,
    DesiredAccess: windows.ACCESS_MASK,
    ObjectAttributes: *const windows.OBJECT.ATTRIBUTES,
    TitleIndex: windows.ULONG,
    Class: ?*const windows.UNICODE_STRING,
    CreateOptions: windows.ULONG,
    Disposition: ?*windows.ULONG,
) callconv(.winapi) windows.NTSTATUS;

extern "ntdll" fn NtSetValueKey(
    KeyHandle: windows.HANDLE,
    ValueName: *const windows.UNICODE_STRING,
    TitleIndex: windows.ULONG,
    Type: windows.REG.ValueType,
    Data: [*]const u8,
    DataSize: windows.ULONG,
) callconv(.winapi) windows.NTSTATUS;

pub fn handler(
    io: Io,
    environ: *Environ.Map,
    application_id: []const u8,
    command: ?[]const u8,
) Error!void {
    _ = io;
    _ = environ;
    assert(application_id.len > 0);

    var executable: [max_path_wide]u16 = undefined;
    const executable_wide = try executablePath(&executable);

    var command_storage: [max_path_wide]u16 = undefined;
    const open_command = if (command) |text|
        try toWide(&command_storage, text)
    else
        executable_wide;

    return write(application_id, executable_wide, open_command);
}

pub const steam_command_bytes = max_path_wide;

/// The registry stores a command line, so the URL is handed to the installed Steam. Quoted
/// because an installation path may hold spaces.
pub fn steamCommand(out: []u8, steam_id: []const u8) Error![]u8 {
    assert(steam_id.len > 0);

    var steam_storage: [max_path_wide]u8 = undefined;
    const steam_path = try steamExecutable(&steam_storage);

    const command = std.fmt.bufPrint(out, "\"{s}\" " ++ steam_url_prefix ++ "{s}", .{
        steam_path,
        steam_id,
    }) catch return error.NameTooLong;

    assert(command.len > steam_id.len);
    return command;
}

fn write(
    application_id: []const u8,
    executable: [:0]const u16,
    open_command: [:0]const u16,
) Error!void {
    const user_key = try openCurrentUser(key_write);
    defer windows.CloseHandle(user_key);

    var protocol_storage: [scheme_bytes]u8 = undefined;
    const name = std.fmt.bufPrint(
        &protocol_storage,
        scheme_prefix ++ "{s}",
        .{application_id},
    ) catch return error.NameTooLong;

    const protocol_key = try createKeyPath(user_key, &.{ "Software", "Classes", name });
    defer windows.CloseHandle(protocol_key);

    var description_storage: [128]u8 = undefined;
    const description = std.fmt.bufPrint(
        &description_storage,
        "URL:Run game {s} protocol",
        .{application_id},
    ) catch return error.NameTooLong;
    var description_wide: [256]u16 = undefined;
    try setString(protocol_key, "", try toWide(&description_wide, description));

    // The empty `URL Protocol` value is the marker; its content is never read.
    try setString(protocol_key, "URL Protocol", &[_:0]u16{});

    const icon_key = try createKeyPath(protocol_key, &.{"DefaultIcon"});
    defer windows.CloseHandle(icon_key);
    try setString(icon_key, "", executable);

    const command_key = try createKeyPath(protocol_key, &.{ "shell", "open", "command" });
    defer windows.CloseHandle(command_key);
    try setString(command_key, "", open_command);
}

/// A key can only be created directly under one that already exists.
fn createKeyPath(root: windows.HANDLE, components: []const []const u8) Error!windows.HANDLE {
    assert(components.len > 0);

    var parent = root;
    errdefer if (parent != root) windows.CloseHandle(parent);

    for (components) |component| {
        assert(component.len > 0);
        const child = try createKey(parent, component);
        if (parent != root) windows.CloseHandle(parent);
        parent = child;
    }

    assert(parent != root);
    return parent;
}

fn createKey(parent: windows.HANDLE, name: []const u8) Error!windows.HANDLE {
    assert(name.len > 0);

    var name_storage: [256]u16 = undefined;
    var name_wide: windows.UNICODE_STRING = .init(try toWide(&name_storage, name));
    const attributes = objectAttributes(parent, &name_wide);

    var key: windows.HANDLE = undefined;
    return switch (NtCreateKey(&key, key_write, &attributes, 0, null, 0, null)) {
        .SUCCESS => key,
        else => error.RegistryUnavailable,
    };
}

/// An empty `name` writes the default value, where the shell looks for these.
fn setString(key: windows.HANDLE, name: []const u8, value: [:0]const u16) Error!void {
    var name_storage: [64]u16 = undefined;
    const name_wide: windows.UNICODE_STRING = .init(try toWide(&name_storage, name));

    const byte_length: windows.ULONG = @intCast((value.len + 1) * @sizeOf(u16));
    const data: [*]const u8 = @ptrCast(value.ptr);
    return switch (NtSetValueKey(key, &name_wide, 0, .SZ, data, byte_length)) {
        .SUCCESS => {},
        else => error.RegistryUnavailable,
    };
}

/// The process parameters already hold the image path as UTF-16, which is what the registry
/// wants. A UTF-8 form would need `max_path_bytes`, 98302 on Windows.
fn executablePath(out: []u16) Error![:0]u16 {
    const image = windows.peb().ProcessParameters.ImagePathName;
    const path = image.slice();
    if (path.len == 0) return error.NoExecutablePath;

    // A registry value carries its own terminator, so there is room for one past the path.
    if (path.len + 1 > out.len) return error.NameTooLong;

    @memcpy(out[0..path.len], path);
    out[path.len] = 0;
    return out[0..path.len :0];
}

fn openCurrentUser(access: windows.ACCESS_MASK) Error!windows.HANDLE {
    var user_key: windows.HANDLE = undefined;
    return switch (windows.ntdll.RtlOpenCurrentUser(access, &user_key)) {
        .SUCCESS => user_key,
        else => error.RegistryUnavailable,
    };
}

fn objectAttributes(
    root: windows.HANDLE,
    name: *windows.UNICODE_STRING,
) windows.OBJECT.ATTRIBUTES {
    return .{
        .RootDirectory = root,
        .ObjectName = name,
        .Attributes = .{ .INHERIT = false },
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };
}

fn steamExecutable(out: []u8) Error![]u8 {
    const user_key = try openCurrentUser(key_read);
    defer windows.CloseHandle(user_key);

    var path_storage: [64]u16 = undefined;
    const steam_key_path = try toWide(&path_storage, "Software\\Valve\\Steam");
    var path_wide: windows.UNICODE_STRING = .init(steam_key_path);
    const attributes = objectAttributes(user_key, &path_wide);

    var steam_key: windows.HANDLE = undefined;
    switch (windows.ntdll.NtOpenKey(&steam_key, key_read, &attributes)) {
        .SUCCESS => {},
        else => return error.NoSteamInstallation,
    }
    defer windows.CloseHandle(steam_key);

    var name_storage: [16]u16 = undefined;
    const value_name: windows.UNICODE_STRING = .init(try toWide(&name_storage, "SteamExe"));

    const Partial = windows.KEY.VALUE.PARTIAL_INFORMATION;
    var information: [@sizeOf(Partial) + max_path_wide * @sizeOf(u16)]u8 align(@alignOf(Partial)) =
        undefined;
    var result_length: windows.ULONG = 0;
    switch (windows.ntdll.NtQueryValueKey(
        steam_key,
        &value_name,
        .Partial,
        &information,
        information.len,
        &result_length,
    )) {
        .SUCCESS => {},
        else => return error.NoSteamInstallation,
    }

    const partial: *const windows.KEY.VALUE.PARTIAL_INFORMATION = @ptrCast(&information);
    const bytes = partial.data();
    if (bytes.len < @sizeOf(u16)) return error.NoSteamInstallation;

    const even = bytes[0 .. @divTrunc(bytes.len, @sizeOf(u16)) * @sizeOf(u16)];
    const wide: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, even));
    const units = std.mem.sliceTo(wide, 0);

    // `utf16LeToUtf8` assumes the destination is large enough, and the hive is user-writable.
    // One unit costs up to three bytes of UTF-8.
    if (units.len * 3 > out.len) return error.NameTooLong;

    const length = std.unicode.utf16LeToUtf8(out, units) catch return error.InvalidUtf8;
    assert(length <= out.len);

    // Steam stores its path with forward slashes, which the shell will not run.
    std.mem.replaceScalar(u8, out[0..length], '/', '\\');
    return out[0..length];
}

/// `utf8ToUtf16Le` assumes the destination is large enough, so the bound is checked here: one
/// UTF-8 byte yields at most one UTF-16 unit. The result is terminated, as a registry value
/// carries its terminator into the hive.
fn toWide(out: []u16, text: []const u8) Error![:0]u16 {
    if (text.len + 1 > out.len) return error.NameTooLong;

    const length = std.unicode.utf8ToUtf16Le(out, text) catch return error.InvalidUtf8;
    assert(length <= text.len);

    out[length] = 0;
    return out[0..length :0];
}

test toWide {
    var out: [8]u16 = undefined;
    try std.testing.expectEqualSlices(u16, &.{ 'c', 'm', 'd' }, try toWide(&out, "cmd"));

    // Seven characters and a terminator is the whole buffer; eight overruns it.
    _ = try toWide(&out, "1234567");
    try std.testing.expectError(error.NameTooLong, toWide(&out, "12345678"));

    try std.testing.expectError(error.InvalidUtf8, toWide(&out, "\xff"));
}
