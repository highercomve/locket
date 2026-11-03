const std = @import("std");
const oriel = @import("oriel");
const zigatlas = @import("zigatlas");

/// The one version: build.zig.zon's. `locket --version`, the window, the
/// packages and the update manifests all read it from here.
const version = @import("build.zig.zon").version;

/// The public half of the key that signs every release's update manifests
/// (latest.json for locket-app, latest-cli.json for locket). The private
/// half is the LOCKET_UPDATE_KEY secret (.github/workflows/release.yml).
const update_public_key = "w0xKXvihKtXMT/lpZ9lBX/WFTLCCJhGgujAYTN0khzM=";

pub fn build(b: *std.Build) void {
    // On macOS, a target without a version builds for macOS 13+ (not just
    // the Mac building it); pass this target to every executable you add.
    const target = oriel.resolveTarget(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});
    // -Dapp=false: only the CLI (cross-compiled CLI builds need no GUI).
    const with_app = b.option(bool, "app", "Build locket-app too (default true)") orelse true;

    // What `locket --version` and the window show, and what updates compare.
    const info = b.addOptions();
    info.addOption([]const u8, "version", version);
    info.addOption([]const u8, "commit", gitCommit(b) orelse "unknown");
    info.addOption([]const u8, "update_public_key", update_public_key);
    const info_module = info.createModule();

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
        // Updates from the GitHub releases (src/desktop/updates.zig).
        .updater = true,
        .sql = false,
        .fs_watch = false,
        .media_server = false,
        .global_shortcut = false,
        .input = false,
        // Copying a variable's name (src/desktop/app.zig: copyName).
        .clipboard = true,
    });

    // The CLI (`zig build cli`, binary zig-out/bin/locket). Same vault
    // core as the desktop app (locket-app); no renderer, no window, no GTK.
    // `locket update` uses Oriel's updater engine (std only, no GUI).
    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/cli_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_info", .module = info_module },
            .{ .name = "oriel_updater", .module = dep.module("oriel_updater") },
        },
    });
    const cli = b.addExecutable(.{
        .name = "locket",
        .root_module = cli_module,
    });
    b.installArtifact(cli);

    if (with_app) _ = oriel.addApp(b, dep, .{
        .name = "locket-app",
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{.{ .name = "build_info", .module = info_module }},
        .icon = b.path("icon.png"), // High-resolution PNG (1024x1024 recommended)
        .update_public_key = update_public_key,
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
            .publisher = "foreachdeveloper",
            .homepage = "https://locket.foreachdeveloper.com",
            .summary = "A local secrets vault for AI agents",
            .version = version,
            // The CLI ships inside every package: /usr/bin/locket from the
            // deb and rpm, next to the app on Windows and in the .app.
            .contents = .{ .executables = &.{cli} },
        },
    });

    const run_cli = b.addRunArtifact(cli);
    run_cli.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cli.addArgs(args);
    b.step("cli", "Run the locket CLI").dependOn(&run_cli.step);

    // zig build test: the vault core, the CLI and the window's input
    // decoding (the files that don't need a window to run).
    const test_step = b.step("test", "Run the unit tests");
    for ([_][]const u8{ "src/vault.zig", "src/sync.zig", "src/cli.zig", "src/cli_sync.zig", "src/cli_complete.zig", "src/update_errors.zig", "src/desktop/input.zig" }) |path| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_info", .module = info_module },
                .{ .name = "oriel_updater", .module = dep.module("oriel_updater") },
            },
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // zig build atlas: the code map for reviewers and LLM agents.
    _ = zigatlas.addAtlasStep(b, .{
        .roots = &.{"src"},
        .layers = &.{
            .{ .name = "app", .paths = &.{ "src/main.zig", "src/cli_main.zig" }, .thin = true },
            .{ .name = "front", .paths = &.{ "src/cli.zig", "src/cli_sync.zig", "src/cli_complete.zig", "src/update.zig", "src/update_errors.zig", "src/desktop" } },
            .{ .name = "sync", .paths = &.{ "src/sync.zig", "src/sync" } },
            .{ .name = "core", .paths = &.{"src"} },
        },
        // core is the foundation; nothing imports up. Redundant: layers
        // already forbid upward imports, but saying why matters.
        .forbid = &.{
            .{ .from = "core", .to = "app", .reason = "core must not reach a front end" },
        },
    });
}

/// The commit being built (`+` when the tree has uncommitted changes).
fn gitCommit(b: *std.Build) ?[]const u8 {
    const root = b.build_root.path orelse ".";
    var code: u8 = 0;
    const out = b.runAllowFail(&.{ "git", "-C", root, "rev-parse", "--short=10", "HEAD" }, &code, .ignore) catch return null;
    const commit = std.mem.trim(u8, out, " \n\r");
    if (commit.len == 0) return null;
    const status = b.runAllowFail(&.{ "git", "-C", root, "status", "--porcelain", "--untracked-files=no" }, &code, .ignore) catch return commit;
    return if (std.mem.trim(u8, status, " \n\r").len > 0) b.fmt("{s}+", .{commit}) else commit;
}
