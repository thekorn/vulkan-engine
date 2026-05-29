const std = @import("std");
const builtin = @import("builtin");

const shaders_dir = "./shaders";

/// A step that runs kcov on an artifact binary (requires kcov to be
/// installed). Adapted from https://github.com/vancluever/z2d.
fn coverStep(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    clean: bool,
    open: bool,
) *std.Build.Step {
    const dir = b.pathJoin(&.{ b.install_prefix, "cover" });

    // Only pass the kcov `--clean` flag when the caller asked for it, so
    // a plain `zig build coverage` run with `clean=false` preserves the
    // existing report directory.
    var kcov_argv: std.ArrayList([]const u8) = .empty;
    kcov_argv.append(b.allocator, "kcov") catch @panic("OOM");
    if (clean) kcov_argv.append(b.allocator, "--clean") catch @panic("OOM");
    kcov_argv.append(b.allocator, "--include-pattern=src/") catch @panic("OOM");
    kcov_argv.append(b.allocator, dir) catch @panic("OOM");

    const coverage_command = b.addSystemCommand(kcov_argv.items);
    coverage_command.addArtifactArg(artifact);

    const mkdir_command = b.addSystemCommand(&.{ "mkdir", "-p", dir });
    coverage_command.step.dependOn(&mkdir_command.step);

    if (clean) {
        const clean_command = b.addSystemCommand(&.{ "rm", "-rf", dir });
        mkdir_command.step.dependOn(&clean_command.step);
    }

    // Compact terminal summary of the kcov report so the user can see
    // the coverage numbers without opening the HTML report. The per-run
    // JSON lives at `<dir>/<binary>.<hash>/coverage.json`; we glob for
    // it and let `jq` format totals plus a per-file breakdown sorted
    // by ascending coverage (worst first).
    const summary_script = b.fmt(
        \\set -eu
        \\f=$(ls {s}/*/coverage.json 2>/dev/null | head -n1)
        \\if [ -z "$f" ]; then
        \\  echo "coverage: no coverage.json found under {s}" >&2
        \\  exit 0
        \\fi
        \\echo
        \\jq -r '"coverage: \(.percent_covered)% (\(.covered_lines)/\(.total_lines) lines)"' "$f"
        \\jq -r '.files | sort_by(.percent_covered|tonumber) | .[] | "  \(.percent_covered)%\t\(.covered_lines)/\(.total_lines)\t\(.file|sub(".*/src/";""))"' "$f"
        \\echo
    , .{ dir, dir });

    const summary_command = b.addSystemCommand(&.{ "sh", "-c", summary_script });
    summary_command.step.dependOn(&coverage_command.step);

    if (!open) return &summary_command.step;

    const open_command = b.addSystemCommand(&.{
        if (builtin.target.os.tag == .linux) "xdg-open" else "open",
        b.pathJoin(&.{ dir, "index.html" }),
    });
    open_command.step.dependOn(&summary_command.step);
    return &open_command.step;
}

fn compileAllShaders(b: *std.Build, exe: anytype) !void {
    const io = b.graph.io;
    var dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, shaders_dir, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(b.allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        const out_file = try std.fmt.allocPrint(b.allocator, "{s}.spv", .{entry.path});
        defer b.allocator.free(out_file);
        std.debug.print("compiling shader: {s} -> {s}\n", .{ entry.path, out_file });
        addShader(b, exe, entry.path, out_file) catch |e| {
            std.debug.print("Failed to compile vertex shader '{s}': {}\n", .{ entry.path, e });
        };
    }
}

fn addShader(b: *std.Build, exe: anytype, in_file: []const u8, out_file: []const u8) !void {
    // example:
    // glslc -o shaders/vert.spv shaders/shader.vert
    const full_in = try std.fs.path.join(b.allocator, &[_][]const u8{ shaders_dir, in_file });

    const run_cmd = b.addSystemCommand(&[_][]const u8{
        "glslc",
    });

    run_cmd.addArg("-o");

    const output = run_cmd.addOutputFileArg(out_file);

    // Pass the input shader as a tracked file dependency so the build
    // system re-runs glslc whenever the shader source changes.
    run_cmd.addFileArg(b.path(full_in));
    exe.step.dependOn(&run_cmd.step);

    exe.root_module.addAnonymousImport(out_file, .{
        .root_source_file = output,
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "vulkan_engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.linkSystemLibrary("glfw3", .{});
    exe.root_module.linkSystemLibrary("vulkan", .{});
    exe.root_module.linkSystemLibrary("cglm", .{});

    if (target.result.os.tag == .linux) {
        exe.root_module.link_libc = true;
        exe.root_module.linkSystemLibrary("gl", .{});
    }

    compileAllShaders(b, exe) catch |e| {
        std.debug.print("Failed to compile shaders: {}\n", .{e});
    };

    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const cover = b.option(
        bool,
        "cover",
        "Generate a coverage report for the test step using kcov (implies use_llvm=true)",
    ) orelse false;
    const clean = b.option(
        bool,
        "clean",
        "Clean the coverage output directory before running kcov",
    ) orelse false;
    const open = b.option(
        bool,
        "open",
        "Open the generated coverage report after the test step finishes",
    ) orelse false;

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        // kcov needs DWARF debug info, which the LLVM backend reliably
        // produces. Force LLVM whenever coverage is requested.
        .use_llvm = if (cover) true else null,
    });
    const test_step = b.step("test", "Run tests");
    if (cover) {
        test_step.dependOn(coverStep(b, exe_tests, clean, open));
    } else {
        const run_exe_tests = b.addRunArtifact(exe_tests);
        test_step.dependOn(&run_exe_tests.step);
    }

    // Dedicated coverage step: always uses the LLVM backend so kcov has
    // the DWARF debug info it needs, independent of the `-Dcover` flag
    // that toggles coverage on the regular `test` step.
    const coverage_tests = b.addTest(.{
        .root_module = exe.root_module,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        .use_llvm = true,
    });
    const coverage_step = b.step("coverage", "Run tests under kcov and write a coverage report to zig-out/cover");
    coverage_step.dependOn(coverStep(b, coverage_tests, true, false));
}
