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

    // zig_rb's build.zig calls `zig_tests.linkSystemLibrary("ruby")` on a
    // Compile step whose root_module is the same module exported to
    // consumers; via the deprecated alias, that mutates the shared module's
    // link_objects with a "ruby" system_lib. Inheriting it would bake an
    // absolute libruby path into the macOS bundle and pull in whatever
    // libruby Linux's ld happens to resolve (often the runner's system
    // Ruby, breaking cross-version loads). Strip it here; Ruby's C-API
    // symbols are resolved at dlopen against the host ruby process, like
    // every other distributable Ruby native extension.
    const rb_module = zig_rb_dep.module("zig_rb");
    var i: usize = 0;
    while (i < rb_module.link_objects.items.len) {
        const lo = rb_module.link_objects.items[i];
        if (lo == .system_lib and std.mem.eql(u8, lo.system_lib.name, "ruby")) {
            _ = rb_module.link_objects.orderedRemove(i);
        } else {
            i += 1;
        }
    }

    const fibers_module = b.createModule(.{
        .root_source_file = b.path("ext/carbon_fiber_native/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "rb", .module = rb_module },
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

    // macOS' linker rejects undefined symbols in shared libraries by default;
    // Linux' ld permits them. Allow undefined Ruby C-API symbols on macOS so
    // dyld resolves them at dlopen against the host ruby process.
    const is_macos = target.result.os.tag == .macos;
    if (is_macos) fibers_ext.linker_allow_shlib_undefined = true;

    // Enable full LTO for release builds to allow cross-module inlining between
    // the event loop, I/O helpers, and Ruby binding layers.
    // macOS excluded: Zig 0.15's linker can't resolve Xcode 26.4 TBD entries,
    // so we use DEVELOPER_DIR=/dev/null which bypasses the system SDK but also
    // prevents LLD (required for LTO) from linking against libSystem.
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

    // Ruby's require on macOS only recognises files whose extension matches
    // RbConfig::CONFIG["DLEXT"], which is "bundle" on darwin and "so" on
    // linux. Naming mismatch means native.rb silently falls through to the
    // pure-Ruby fallback on fresh macOS installs.
    const dlext = if (is_macos) "bundle" else "so";

    const copy_cmd = b.addSystemCommand(&.{
        "sh",
        "-c",
        std.fmt.allocPrint(
            allocator,
            "mkdir -p {s} && cp $1 {s}/carbon_fiber_native.{s}",
            .{ dest_path, dest_path, dlext },
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
