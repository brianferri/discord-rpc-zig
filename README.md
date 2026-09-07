# discord-rpc-zig

A Zig client for Discord's local Rich Presence IPC.

It connects to the Discord desktop client over its local endpoint, reports what the
player is doing, and carries the events and commands the RPC protocol defines back
and forth.

Currently supported platforms:

* Linux (unix socket)
* macOS (unix socket)
* Windows (named pipe, through `ntdll`)

## Requirements

* Zig 0.17.0-dev.1786+
* Linux, macOS or Windows

## Use it

```sh
zig fetch --save git+https://github.com/brianferri/discord-rpc-zig
```

```zig
const discord = b.dependency("discord_rpc", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("discord_rpc", discord.module("discord_rpc"));
```

```zig
const discord = @import("discord_rpc");

pub fn main(init: std.process.Init) !void {
    const client = try init.gpa.create(discord.Client);
    defer init.gpa.destroy(client);

    client.init(.{ .application_id = "your application id" });
    defer client.deinit(init.io);

    try client.subscribe(init.io, .activity_join, "");
    try client.subscribe(init.io, .activity_join_request, "");

    try client.start(init.io, init.environ_map);

    while (running) {
        try client.updatePresence(init.io, &.{ .state = "In the lobby" });

        while (try client.nextEvent(init.io)) |event| switch (event) {
            .ready => |user| std.log.info("connected as {s}", .{user.username.slice()}),
            .join_request => |user| try client.respond(init.io, user.id.slice(), .yes),
            else => {},
        };
    }
}
```

Get an application id from the [Discord developer site](https://discord.com/developers/applications).

`zig build` also emits `discord-rpc-c`, a C ABI over the same client, and
`examples/presence.lua` drives it from LuaJIT.

I try to follow [Tiger Style](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).

## Documentation

The documentation is the source. `src/root.zig` and `src/c.zig` open with the guide to their surface:

* [The library](https://brianferri.github.io/discord-rpc-zig/)
* [The C ABI](https://brianferri.github.io/discord-rpc-zig/c/)

To read them from a checkout instead:

```sh
zig build docs   # zig-out/docs for the library, zig-out/docs/c for the C ABI
```

Serve `zig-out/docs` over HTTP to read it; the pages load their sources over `fetch`.

## Building

```sh
zig build       # the C ABI library and the example
zig build lib   # the C ABI library on its own
zig build run   # the send-presence example
```

`-Dlinkage=static` emits an archive instead of a shared library. Each
[release](https://github.com/brianferri/discord-rpc-zig/releases) carries both, built for
every supported system.

## Testing

```sh
zig build test         # unit tests, plus a client driven against a fake endpoint
zig build test --fuzz  # drive the coverage-guided fuzz targets
```

## Profiling

`zig build bench` emits a fixed workload, one case per code path, and `bench/profile.sh`
reports what each costs:

```sh
zig build bench
./bench/profile.sh table              # every case, side by side
./bench/profile.sh hot parse_ready    # where one case spends its instructions
./bench/profile.sh help
```

It needs `valgrind`. A case runs on its own so a profiler attributes cleanly, and the table
subtracts an empty-loop baseline. Instructions are given per round, and misses per million
data references, so a miss column reads as a rate and says whether a working set outgrew the
cache.

## Testing on the other systems

To run the suite on the other supported systems, cross-build it and use one of the
provided docker configurations:

```sh
zig build cross    # one suite per target into zig-out/cross
./dc [linux|windows] up
./dc [linux|windows] log
```

`linux` serves glibc and musl, plus a `sandbox` service whose runtime directory carries the
endpoint under a Flatpak layout; `windows` runs the PE suite under wine. An `arm64`
service sits behind the `emulated` profile, which needs a host-wide registration
first:

```sh
docker run --privileged tonistiigi/binfmt --install arm64
COMPOSE_PROFILES=emulated ./dc linux up
```

macOS is cross-built and inspected only; no container runs it yet.
