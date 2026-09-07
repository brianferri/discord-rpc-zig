//! Windows named pipe at `\??\pipe\discord-ipc-N`, opened for asynchronous IO.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const windows = std.os.windows;

const endpoint = @import("endpoint.zig");
const transport = @import("root.zig");

const Pipe = @This();

handle: windows.HANDLE,

/// One completion object per direction; a reader and a writer hold the same pipe at once.
read_event: windows.HANDLE,
write_event: windows.HANDLE,

pub const OpenError = endpoint.OpenError;

const path_prefix = std.unicode.utf8ToUtf16LeStringLiteral(endpoint.pipe_path_prefix);

pub fn open(io: Io, environ: *std.process.Environ.Map) OpenError!Pipe {
    _ = io;
    // Fixed on Windows; the parameter exists so both transports open the same way.
    _ = environ;

    comptime assert(endpoint.count <= 10);
    var path_buffer: [path_prefix.len + 1]u16 = undefined;
    @memcpy(path_buffer[0..path_prefix.len], path_prefix);

    var number: u32 = 0;
    while (number < endpoint.count) : (number += 1) {
        path_buffer[path_prefix.len] = endpoint.digit(number);

        const handle = openEndpoint(&path_buffer) catch continue;
        errdefer windows.CloseHandle(handle);

        const read_event = createEvent() catch return error.NoEndpoint;
        errdefer windows.CloseHandle(read_event);
        const write_event = createEvent() catch return error.NoEndpoint;

        return .{ .handle = handle, .read_event = read_event, .write_event = write_event };
    }

    assert(number == endpoint.count);
    return error.NoEndpoint;
}

fn openEndpoint(path: []const u16) error{Unavailable}!windows.HANDLE {
    assert(path.len > path_prefix.len);

    var name: windows.UNICODE_STRING = .init(path);
    const attributes = objectAttributes(&name);

    var handle: windows.HANDLE = undefined;
    var io_status_block: windows.IO_STATUS_BLOCK = undefined;
    return switch (windows.ntdll.NtCreateFile(
        &handle,
        .{
            .GENERIC = .{ .READ = true, .WRITE = true },
            .STANDARD = .{ .SYNCHRONIZE = true },
        },
        &attributes,
        &io_status_block,
        null,
        .{ .NORMAL = true },
        .VALID_FLAGS,
        .OPEN,
        .{ .NON_DIRECTORY_FILE = true, .IO = .ASYNCHRONOUS },
        null,
        0,
    )) {
        .SUCCESS => handle,
        else => error.Unavailable,
    };
}

/// Names an object in the NT namespace by absolute path.
pub fn objectAttributes(name: *windows.UNICODE_STRING) windows.OBJECT.ATTRIBUTES {
    return .{
        .RootDirectory = null,
        .ObjectName = name,
        .Attributes = .{ .INHERIT = false },
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };
}

/// Auto-resetting, so each completion consumes exactly one signal.
pub fn createEvent() error{Unavailable}!windows.HANDLE {
    var event: windows.HANDLE = undefined;
    return switch (windows.ntdll.NtCreateEvent(
        &event,
        .{ .STANDARD = .{ .SYNCHRONIZE = true }, .GENERIC = .{ .WRITE = true } },
        null,
        .Synchronization,
        .FALSE,
    )) {
        .SUCCESS => event,
        else => error.Unavailable,
    };
}

/// Waits for the operation the status block describes. A reached deadline cancels it and
/// waits for the cancellation; an operation that completed in that window is a success.
fn awaitCompletion(
    pipe: *Pipe,
    event: windows.HANDLE,
    status: windows.NTSTATUS,
    io_status_block: *windows.IO_STATUS_BLOCK,
    timeout: ?windows.LARGE_INTEGER,
) transport.OperationError!void {
    switch (status) {
        .SUCCESS => return,
        .PENDING => {},
        else => return error.ConnectionClosed,
    }

    const relative: ?*const windows.LARGE_INTEGER = if (timeout) |*value| value else null;
    switch (windows.ntdll.NtWaitForSingleObject(event, .FALSE, relative)) {
        .SUCCESS => {},
        .TIMEOUT => {
            var cancel_block: windows.IO_STATUS_BLOCK = undefined;
            _ = windows.ntdll.NtCancelIoFileEx(pipe.handle, io_status_block, &cancel_block);
            _ = windows.ntdll.NtWaitForSingleObject(event, .FALSE, null);

            if (io_status_block.u.Status == .SUCCESS) return;
            return error.Timeout;
        },
        else => return error.ConnectionClosed,
    }

    if (io_status_block.u.Status != .SUCCESS) return error.ConnectionClosed;
}

/// Negative is relative, in hundred-nanosecond units.
fn relativeTimeout(io: Io, timeout: Io.Timeout) ?windows.LARGE_INTEGER {
    const duration = timeout.toDurationFromNow(io) orelse return null;
    const remaining = duration.raw.nanoseconds;
    if (remaining <= 0) return 0;
    return -@as(windows.LARGE_INTEGER, @intCast(@divTrunc(remaining, 100)));
}

pub fn close(pipe: *Pipe, io: Io) void {
    _ = io;
    windows.CloseHandle(pipe.handle);
    windows.CloseHandle(pipe.read_event);
    windows.CloseHandle(pipe.write_event);
    pipe.* = undefined;
}

/// Answers with whatever has arrived. A fill that wants all of it is `root.readAll`.
pub fn read(
    pipe: *Pipe,
    io: Io,
    buffer: []u8,
    timeout: Io.Timeout,
) transport.OperationError!usize {
    assert(buffer.len > 0);

    // A pipe has no file position, but the kernel wants somewhere to read one from.
    var offset: windows.LARGE_INTEGER = 0;

    var io_status_block: windows.IO_STATUS_BLOCK = undefined;
    const status = windows.ntdll.NtReadFile(
        pipe.handle,
        pipe.read_event,
        null,
        null,
        &io_status_block,
        buffer.ptr,
        @intCast(buffer.len),
        &offset,
        null,
    );
    try pipe.awaitCompletion(
        pipe.read_event,
        status,
        &io_status_block,
        relativeTimeout(io, timeout),
    );

    const count = io_status_block.Information;
    if (count == 0) return error.ConnectionClosed;

    assert(count <= buffer.len);
    return count;
}

/// Takes as much as the peer will accept now. A write that wants all of it is `root.writeAll`.
pub fn write(
    pipe: *Pipe,
    io: Io,
    bytes: []const u8,
    timeout: Io.Timeout,
) transport.OperationError!usize {
    assert(bytes.len > 0);

    var offset: windows.LARGE_INTEGER = 0;

    var io_status_block: windows.IO_STATUS_BLOCK = undefined;
    const status = windows.ntdll.NtWriteFile(
        pipe.handle,
        pipe.write_event,
        null,
        null,
        &io_status_block,
        bytes.ptr,
        @intCast(bytes.len),
        &offset,
        null,
    );
    try pipe.awaitCompletion(
        pipe.write_event,
        status,
        &io_status_block,
        relativeTimeout(io, timeout),
    );

    const count = io_status_block.Information;
    if (count == 0) return error.ConnectionClosed;

    assert(count <= bytes.len);
    return count;
}

pub fn processId() u32 {
    return windows.GetCurrentProcessId();
}
