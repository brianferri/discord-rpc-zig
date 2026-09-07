const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Named, because this is what a consumer reaches through `dependency(...).module(...)`.
    const discord_rpc = b.addModule("discord_rpc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Windows spells an import library and a static archive both `.lib`, so emitting the two
    // linkages under one name loses whichever is installed first.
    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "How to emit the C ABI library (default dynamic)",
    ) orelse .dynamic;

    const c_api = b.addLibrary(.{
        .linkage = linkage,
        .name = "discord-rpc-c",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "discord_rpc", .module = discord_rpc }},
        }),
    });
    b.installArtifact(c_api);

    const lib_step = b.step("lib", "Install the C ABI library into the prefix");
    lib_step.dependOn(&b.addInstallArtifact(c_api, .{}).step);

    const example = b.addExecutable(.{
        .name = "send-presence",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/send_presence.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "discord_rpc", .module = discord_rpc }},
        }),
    });
    b.installArtifact(example);

    // A fixed workload for the profilers: `valgrind --tool=cachegrind zig-out/bin/bench`.
    //
    // The library reaches this through a module of its own, so what is profiled is what ships
    // whatever mode the rest of the build is in.
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/presence.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "discord_rpc", .module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = target,
                .optimize = .ReleaseFast,
            }) }},
        }),
    });

    const bench_step = b.step("bench", "Build the profiling workload into zig-out/bin");
    bench_step.dependOn(&b.addInstallArtifact(bench, .{}).step);

    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());
    run_example.addPassthruArgs();
    const run_step = b.step("run", "Run the send-presence example");
    run_step.dependOn(&run_example.step);

    // `--fuzz` drives one target at a time, so selecting it is how a run is aimed at one.
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run tests whose name contains this; repeatable",
    ) orelse &.{};

    const unit_tests = b.addTest(.{
        .root_module = discord_rpc,
        // The suite hosts the coverage-guided fuzzer (`std.testing.fuzz`). The program-counter
        // table `--fuzz` slices to guide mutation is only emitted by the LLVM backend; under
        // the self-hosted backend the table is empty and the fuzzer panics slicing it. Force
        // LLVM until self-hosted fuzz coverage lands.
        //   https://codeberg.org/ziglang/zig/issues/30655
        .use_llvm = true,
        .filters = test_filters,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    // With `-Dtarget` set to something this host cannot execute, the suite is still built,
    // so the step stays a portability check for every target the library claims.
    run_unit_tests.skip_foreign_checks = true;

    const test_step = b.step("test", "Run unit tests; --fuzz drives the fuzz targets");
    test_step.dependOn(&run_unit_tests.step);

    // Standalone suites for the systems the library claims, emitted where the compose
    // services mount them so a foreign system can run what this host cannot execute.
    const cross = b.step("cross", "Build the suite for every supported target into zig-out/cross");
    for ([_][]const u8{
        "x86_64-linux-gnu",
        "x86_64-linux-musl",
        "aarch64-linux-musl",
        "x86_64-windows",
        "aarch64-macos",
        "x86_64-macos",
        "x86_64-freebsd",
        "x86_64-netbsd",
        "x86_64-openbsd",
    }) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch
            @panic("unsupported target triple");
        const cross_tests = b.addTest(.{
            .name = b.fmt("test-{s}", .{triple}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = b.resolveTargetQuery(query),
                .optimize = optimize,
            }),
        });
        cross.dependOn(&b.addInstallArtifact(cross_tests, .{
            .dest_dir = .{ .override = .{ .custom = "cross" } },
        }).step);
    }

    const docs_step = b.step("docs", "Install docs into zig-out/docs");
    for ([_]struct { name: []const u8, module: *std.Build.Module, subdir: []const u8 }{
        .{ .name = "discord-rpc", .module = discord_rpc, .subdir = "docs" },
        .{ .name = "c", .module = c_api.root_module, .subdir = "docs/c" },
    }) |surface| {
        const object = b.addObject(.{ .name = surface.name, .root_module = surface.module });
        docs_step.dependOn(&b.addInstallDirectory(.{
            .source_dir = object.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = surface.subdir,
        }).step);
    }

    // https://kristoff.it/blog/improving-your-zls-experience/
    const check = b.step("check", "Check that the library and example compile");
    check.dependOn(&b.addLibrary(.{
        .linkage = .static,
        .name = "discord-rpc",
        .root_module = discord_rpc,
    }).step);
    check.dependOn(&c_api.step);
    check.dependOn(&example.step);

    const version_file = b.addWriteFiles().add("version", manifest.version ++ "\n");
    const version_step = b.step("version", "Write the version this package names to the prefix");
    version_step.dependOn(&b.addInstallFileWithDir(version_file, .prefix, "version").step);
}
