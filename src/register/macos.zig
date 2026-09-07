//! macOS cannot register an arbitrary command as a URL handler, so a command is saved to a
//! file the client reads; without one the bundle claims the scheme through LaunchServices,
//! the only path a sandboxed application has.
//!
//! CoreServices is loaded with `std.DynLib` when needed: linking it would put a macOS SDK
//! in the way of building for macOS at all.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Environ = std.process.Environ;

const protocol = @import("root.zig");

pub const Error = protocol.Error;
const scheme_prefix = protocol.scheme_prefix;
const scheme_bytes = protocol.scheme_bytes;
const steam_url_prefix = protocol.steam_url_prefix;

const core_services_path = "/System/Library/Frameworks/CoreServices.framework/CoreServices";

/// `kCFStringEncodingUTF8`.
const utf8_encoding: u32 = 0x08000100;

const CFTypeRef = *const opaque {};
const CFAllocatorRef = ?*const opaque {};
const CFStringRef = *const opaque {};
const CFURLRef = *const opaque {};
const CFBundleRef = *const opaque {};

const Symbols = struct {
    CFStringCreateWithBytes: *const fn (
        allocator: CFAllocatorRef,
        bytes: [*]const u8,
        length: c_long,
        encoding: u32,
        is_external_representation: u8,
    ) callconv(.c) ?CFStringRef,
    CFRelease: *const fn (reference: CFTypeRef) callconv(.c) void,
    CFBundleGetMainBundle: *const fn () callconv(.c) ?CFBundleRef,
    CFBundleGetIdentifier: *const fn (bundle: CFBundleRef) callconv(.c) ?CFStringRef,
    CFBundleCopyBundleURL: *const fn (bundle: CFBundleRef) callconv(.c) ?CFURLRef,
    LSSetDefaultHandlerForURLScheme: *const fn (
        scheme: CFStringRef,
        bundle_id: CFStringRef,
    ) callconv(.c) i32,
    LSRegisterURL: *const fn (url: CFURLRef, update: u8) callconv(.c) i32,

    fn resolve(library: *std.DynLib) error{CoreServicesUnavailable}!Symbols {
        var symbols: Symbols = undefined;
        const info = @typeInfo(Symbols).@"struct";
        inline for (info.field_names, info.field_types) |name, Signature| {
            @field(symbols, name) = library.lookup(Signature, name) orelse
                return error.CoreServicesUnavailable;
        }
        return symbols;
    }
};

pub fn handler(
    io: Io,
    environ: *Environ.Map,
    application_id: []const u8,
    command: ?[]const u8,
) Error!void {
    assert(application_id.len > 0);
    if (command) |text| return writeCommandFile(io, environ, application_id, text);
    return claimScheme(application_id);
}

pub const steam_command_bytes = 256;

/// The command file is read by the client and opened as a URL, so the URL is the command.
pub fn steamCommand(out: []u8, steam_id: []const u8) Error![]u8 {
    assert(steam_id.len > 0);

    const command = std.fmt.bufPrint(out, steam_url_prefix ++ "{s}", .{steam_id}) catch
        return error.NameTooLong;

    assert(command.len > steam_id.len);
    return command;
}

/// The command is passed to the client's `window.open`, so it has to be URL-like.
fn writeCommandFile(
    io: Io,
    environ: *Environ.Map,
    application_id: []const u8,
    command: []const u8,
) Error!void {
    const home = environ.get("HOME") orelse "";
    if (home.len == 0) return error.NoHomeDirectory;

    var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = std.fmt.bufPrint(
        &directory_storage,
        "{s}/Library/Application Support/discord/games",
        .{home},
    ) catch return error.NameTooLong;

    var games = Io.Dir.cwd().createDirPathOpen(io, directory, .{}) catch
        return error.RegistrationFailed;
    defer games.close(io);

    var name_storage: [128]u8 = undefined;
    const name = std.fmt.bufPrint(&name_storage, "{s}.json", .{application_id}) catch
        return error.NameTooLong;

    const CommandFile = struct { command: []const u8 };
    var payload_storage: [512]u8 = undefined;
    var writer: Io.Writer = .fixed(&payload_storage);
    std.json.Stringify.value(CommandFile{ .command = command }, .{}, &writer) catch
        return error.NameTooLong;

    games.writeFile(io, .{ .sub_path = name, .data = writer.buffered() }) catch
        return error.RegistrationFailed;
}

fn claimScheme(application_id: []const u8) Error!void {
    var scheme_storage: [scheme_bytes]u8 = undefined;
    const scheme_text = std.fmt.bufPrint(
        &scheme_storage,
        scheme_prefix ++ "{s}",
        .{application_id},
    ) catch return error.NameTooLong;

    var core_services = std.DynLib.open(core_services_path) catch
        return error.CoreServicesUnavailable;
    defer core_services.close();
    const symbols = try Symbols.resolve(&core_services);

    const bundle = symbols.CFBundleGetMainBundle() orelse return error.NoBundle;
    const identifier = symbols.CFBundleGetIdentifier(bundle) orelse return error.NoBundle;
    const url = symbols.CFBundleCopyBundleURL(bundle) orelse return error.NoBundle;
    defer symbols.CFRelease(@ptrCast(url));

    const scheme = symbols.CFStringCreateWithBytes(
        null,
        scheme_text.ptr,
        @intCast(scheme_text.len),
        utf8_encoding,
        0,
    ) orelse return error.RegistrationFailed;
    defer symbols.CFRelease(@ptrCast(scheme));

    if (symbols.LSSetDefaultHandlerForURLScheme(scheme, identifier) != 0) {
        return error.RegistrationFailed;
    }
    if (symbols.LSRegisterURL(url, 1) != 0) return error.RegistrationFailed;
}
