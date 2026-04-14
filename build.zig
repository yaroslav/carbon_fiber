const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_rb_dep = b.dependency("zig_rb", .{
        .target = target,
        .optimize = optimize,
    });
    const libxev_dep = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });

    const fibers_module = b.createModule(.{
        .root_source_file = b.path("ext/carbon_fiber_native/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "rb", .module = zig_rb_dep.module("zig_rb") },
            .{ .name = "xev", .module = libxev_dep.module("xev") },
        },
    });

    const ruby = @import("zig_rb").ruby;
    const ruby_config = ruby.getConfig(b) catch |err| {
        std.debug.print("Failed to get Ruby config: {}\n", .{err});
        return;
    };

    const fibers_ext = ruby.addExtension(
        b,
        &ruby_config,
        .{
            .name = "carbon_fiber_native",
            .root_module = fibers_module,
        },
    );

    // Enable full LTO for release builds to allow cross-module inlining between
    // the event loop, I/O helpers, and Ruby binding layers.
    // macOS excluded: Zig 0.15's linker can't resolve Xcode 26.4 TBD entries,
    // so we use DEVELOPER_DIR=/dev/null which bypasses the system SDK but also
    // prevents LLD (required for LTO) from linking against libSystem.
    const is_macos = target.result.os.tag == .macos;
    if (optimize != .Debug and !is_macos) fibers_ext.lto = .full;

    const allocator = b.allocator;
    const dest_path = std.fmt.allocPrint(
        allocator,
        "lib/carbon_fiber/{s}",
        .{ruby_config.ruby_version},
    ) catch |err| {
        std.debug.print("Failed to build install path: {}\n", .{err});
        b.installArtifact(fibers_ext);
        return;
    };

    const copy_cmd = b.addSystemCommand(&.{
        "sh",
        "-c",
        std.fmt.allocPrint(
            allocator,
            "mkdir -p {s} && cp $1 {s}/carbon_fiber_native.so",
            .{ dest_path, dest_path },
        ) catch |err| {
            std.debug.print("Failed to build copy command: {}\n", .{err});
            b.installArtifact(fibers_ext);
            return;
        },
        "--",
    });
    copy_cmd.addFileArg(fibers_ext.getEmittedBin());
    copy_cmd.step.dependOn(&fibers_ext.step);
    b.getInstallStep().dependOn(&copy_cmd.step);
}
