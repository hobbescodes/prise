const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    if (b.lazyDependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport("vaxis", dep.module("vaxis"));
    }

    const zlua = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua54,
    });
    exe_mod.addImport("zlua", zlua.module("zlua"));

    const exe = b.addExecutable(.{
        .name = "prise",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const os = @import("builtin").os.tag;
    if (os.isDarwin()) {
        const plist = b.addWriteFiles();
        const plist_content = std.fmt.allocPrint(b.allocator,
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0">
            \\<dict>
            \\    <key>Label</key>
            \\    <string>sh.prise.server</string>
            \\    <key>ProgramArguments</key>
            \\    <array>
            \\        <string>{s}/bin/prise</string>
            \\        <string>serve</string>
            \\    </array>
            \\    <key>RunAtLoad</key>
            \\    <true/>
            \\    <key>KeepAlive</key>
            \\    <true/>
            \\    <key>StandardOutPath</key>
            \\    <string>/dev/null</string>
            \\    <key>StandardErrorPath</key>
            \\    <string>/dev/null</string>
            \\</dict>
            \\</plist>
            \\
        , .{b.install_prefix}) catch @panic("OOM");
        _ = plist.add("sh.prise.server.plist", plist_content);
        b.getInstallStep().dependOn(&b.addInstallDirectory(.{
            .source_dir = plist.getDirectory(),
            .install_dir = .{ .custom = "share/prise" },
            .install_subdir = "",
        }).step);
    } else if (os == .linux) {
        b.installFile("dist/prise.service", "lib/systemd/user/prise.service");
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const test_cmd = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_cmd.step);

    const check_fmt = b.addSystemCommand(&.{
        "sh", "-c",
        \\zig fmt --check src build.zig && stylua --check src/lua || {
        \\  echo ""; echo "Format check failed. Run 'zig build fmt' to fix."; exit 1;
        \\}
        ,
    });
    test_step.dependOn(&check_fmt.step);

    const fmt_step = b.step("fmt", "Format Zig and Lua files");

    const fmt_zig = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
        .check = false,
    });
    fmt_step.dependOn(&fmt_zig.step);

    const stylua = b.addSystemCommand(&.{ "stylua", "src/lua" });
    fmt_step.dependOn(&stylua.step);

    const setup_step = b.step("setup", "Setup development environment (install pre-commit hook)");

    const pre_commit_hook =
        \\#!/bin/sh
        \\set -e
        \\zig build fmt
        \\zig build test
    ;

    const setup_hook = b.addSystemCommand(&.{
        "sh",
        "-c",
        b.fmt("mkdir -p .git/hooks && cat > .git/hooks/pre-commit << 'EOF'\n{s}\nEOF\nchmod +x .git/hooks/pre-commit && echo '✓ Pre-commit hook installed'", .{pre_commit_hook}),
    });
    setup_step.dependOn(&setup_hook.step);

    const check_stylua = b.addSystemCommand(&.{
        "sh",
        "-c",
        "command -v stylua > /dev/null || { echo '⚠ Warning: stylua not found. Run: brew install stylua'; }",
    });
    setup_step.dependOn(&check_stylua.step);

    const enable_service_step = b.step("enable-service", "Enable and start the prise server service");
    if (os.isDarwin()) {
        const enable_macos = b.addSystemCommand(&.{
            "sh",
            "-c",
            \\set -e
            \\PLIST_SRC="$1/share/prise/sh.prise.server.plist"
            \\PLIST_DST="$HOME/Library/LaunchAgents/sh.prise.server.plist"
            \\mkdir -p "$HOME/Library/LaunchAgents"
            \\ln -sf "$PLIST_SRC" "$PLIST_DST"
            \\launchctl unload "$PLIST_DST" 2>/dev/null || true
            \\launchctl load "$PLIST_DST"
            \\echo "✓ prise server enabled and started"
            ,
            "--",
        });
        enable_macos.addDirectoryArg(.{ .cwd_relative = b.install_prefix });
        enable_service_step.dependOn(&enable_macos.step);
    } else if (os == .linux) {
        const enable_linux = b.addSystemCommand(&.{
            "sh",
            "-c",
            \\set -e
            \\SERVICE_SRC="$1/lib/systemd/user/prise.service"
            \\SERVICE_DST="$HOME/.config/systemd/user/prise.service"
            \\mkdir -p "$HOME/.config/systemd/user"
            \\ln -sf "$SERVICE_SRC" "$SERVICE_DST"
            \\systemctl --user daemon-reload
            \\systemctl --user enable --now prise.service
            \\echo "✓ prise server enabled and started"
            ,
            "--",
        });
        enable_linux.addDirectoryArg(.{ .cwd_relative = b.install_prefix });
        enable_service_step.dependOn(&enable_linux.step);
    }
    enable_service_step.dependOn(b.getInstallStep());
}
