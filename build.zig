const std = @import("std");
const oriel = @import("oriel");
const zigatlas = @import("zigatlas");

pub fn build(b: *std.Build) void {
    // On macOS, a target without a version builds for macOS 13+ (not just
    // the Mac building it); pass this target to every executable you add.
    const target = oriel.resolveTarget(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});

    // locket-app runs on the Oriel renderer only: compiled .oriel views in
    // src/views, driven from Zig (src/desktop), no web view, no JavaScript.
    const dep = b.dependency("oriel", .{
        .target = target,
        .optimize = optimize,
        .native_ui = true,
        .zig_ui = true,
        .tray = false,
        .menu = false,
        .store = false,
        .dialog = false,
        .notification = false,
        .updater = false,
        .sql = false,
        .fs_watch = false,
        .media_server = false,
        .global_shortcut = false,
        .input = false,
        .clipboard = false,
    });

    _ = oriel.addApp(b, dep, .{
        .name = "locket-app",
        .root_source_file = b.path("src/main.zig"),
        .icon = b.path("icon.png"), // High-resolution PNG (1024x1024 recommended)
        .frontend = .{
            // The .oriel views, embedded as-is: no npm and no dev server.
            .dir = "src/views",
            .dist = ".",
            .build_command = null,
            .install_command = null,
            .dev = null,
            .types_path = null,
        },
        .package = .{
            .id = "com.foreachdeveloper.locket",
            .name = "Locket",
            .summary = "Locket: a local secrets vault for agents",
            .version = "0.1.0",
        },
    });

    // The CLI (`zig build cli`, binary zig-out/bin/locket). Same vault
    // core as the desktop app (locket-app); no renderer, no window, no GTK.
    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/cli_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cli = b.addExecutable(.{
        .name = "locket",
        .root_module = cli_module,
    });
    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    run_cli.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cli.addArgs(args);
    b.step("cli", "Run the locket CLI").dependOn(&run_cli.step);

    // zig build test: the vault core, the CLI and the window's input
    // decoding (the files that don't need a window to run).
    const test_step = b.step("test", "Run the unit tests");
    for ([_][]const u8{ "src/vault.zig", "src/cli.zig", "src/desktop/input.zig" }) |path| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // zig build atlas: the code map for reviewers and LLM agents.
    _ = zigatlas.addAtlasStep(b, .{
        .roots = &.{"src"},
        .layers = &.{
            .{ .name = "app", .paths = &.{ "src/main.zig", "src/cli_main.zig" }, .thin = true },
            .{ .name = "front", .paths = &.{ "src/cli.zig", "src/desktop" } },
            .{ .name = "core", .paths = &.{"src"} },
        },
        // core is the foundation; nothing imports up. Redundant: layers
        // already forbid upward imports, but saying why matters.
        .forbid = &.{
            .{ .from = "core", .to = "app", .reason = "core must not reach a front end" },
        },
    });
}
