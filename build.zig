// zlint-disable no-print -- build scripts legitimately log to stderr via std.debug.print

const std = @import("std");
const builtin = @import("builtin");

const shaders_dir = "./shaders";
const models_dir = "./models";

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
    // Anchor the include pattern to this project's `src/` directory so
    // kcov doesn't also pick up unrelated files that happen to live
    // under a `src/` path — most notably the C++ standard library
    // sources (`<zig>/lib/zig/libcxx/src/...`, `libcxxabi/src/...`)
    // that get pulled in by the tinyobjloader C++ wrapper.
    const include_pattern = b.fmt("--include-pattern={s}/", .{b.pathFromRoot("src")});

    var kcov_argv: std.ArrayList([]const u8) = .empty;
    kcov_argv.append(b.allocator, "kcov") catch @panic("OOM");
    if (clean) kcov_argv.append(b.allocator, "--clean") catch @panic("OOM");
    kcov_argv.append(b.allocator, include_pattern) catch @panic("OOM");
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
    // the coverage numbers without opening the HTML report. kcov
    // maintains a stable `<dir>/test` symlink pointing at the latest
    // per-run output, so we can read `coverage.json` (overall + per-file
    // percentages) and `codecov.json` (per-line hit counts, used to list
    // the uncovered line ranges per file) directly without globbing.
    const coverage_json = b.pathJoin(&.{ dir, "test", "coverage.json" });
    const codecov_json = b.pathJoin(&.{ dir, "test", "codecov.json" });
    const summary_script = b.fmt(
        \\set -eu
        \\echo
        \\jq -r '"coverage: \(.percent_covered)% (\(.covered_lines)/\(.total_lines) lines)"' "{s}"
        \\jq -r '.files | sort_by(.percent_covered|tonumber) | .[] | "  \(.percent_covered)%\t\(.covered_lines)/\(.total_lines)\t\(.file|sub(".*/src/";""))"' "{s}"
        \\echo "uncovered lines:"
        \\jq -r '
        \\  def collapse_ranges:
        \\    reduce .[] as $n ([];
        \\      if length == 0 then [[$n, $n]]
        \\      elif .[-1][1] + 1 == $n then .[:-1] + [[.[-1][0], $n]]
        \\      else . + [[$n, $n]]
        \\      end)
        \\    | map(if .[0] == .[1] then "\(.[0])" else "\(.[0])-\(.[1])" end)
        \\    | join(", ");
        \\  .coverage
        \\  | to_entries
        \\  | map({{file: .key, uncovered: (.value | to_entries | map(select(.value | startswith("0/"))) | map(.key | tonumber) | sort)}})
        \\  | map(select(.uncovered | length > 0))
        \\  | sort_by(.file)
        \\  | if length == 0 then "  (none)" else (.[] | "  \(.file): \(.uncovered | collapse_ranges)") end
        \\' "{s}"
        \\echo
    , .{ coverage_json, coverage_json, codecov_json });

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

/// Walk `models/` and expose each asset file (e.g. `.obj`) to the
/// executable as an anonymous module import keyed by the file's basename
/// (e.g. `smooth_vase.obj`), so call sites can use
/// `@embedFile("smooth_vase.obj")`.
fn embedAllModels(b: *std.Build, exe: anytype) !void {
    const io = b.graph.io;
    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, models_dir, .{ .iterate = true }) catch |err| switch (err) {
        // Tolerate a missing `models/` directory so the project still
        // builds before any asset has been added.
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(b.allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        // Only embed regular files. Skip directories (we still want to
        // walk into them to find files) and other entry kinds.
        if (entry.kind != .file) continue;

        const full_path = try std.fs.path.join(b.allocator, &[_][]const u8{ models_dir, entry.path });
        std.debug.print("embedding model: {s}\n", .{full_path});
        exe.root_module.addAnonymousImport(entry.path, .{
            .root_source_file = b.path(full_path),
        });
    }
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

    // The OBJ loader is a thin C-ABI wrapper around the C++
    // tinyobjloader library. Compiling the wrapper requires libc++ and
    // libc; pulling in tinyobjloader via `linkSystemLibrary` lets
    // pkg-config wire up its include path and static archive.
    exe.root_module.link_libc = true;
    exe.root_module.link_libcpp = true;
    exe.root_module.addIncludePath(b.path("src/wrapper/tinyobj"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/wrapper/tinyobj/tinyobj_wrapper.cpp"),
        .flags = &.{ "-std=c++17", "-fno-exceptions" },
    });
    exe.root_module.linkSystemLibrary("tinyobjloader", .{});

    // Dear ImGui via cimgui. cimgui is a C-ABI wrapper around the C++
    // Dear ImGui library; it expects the upstream imgui repo as an
    // `imgui/` subdirectory next to its own sources (this is the git
    // submodule it normally pulls in). We fetch both via
    // `build.zig.zon` as independent tarballs, then assemble them into
    // one synthetic source tree with `addWriteFiles().addCopyDirectory`
    // so the cimgui `#include "./imgui/imgui.h"` resolves naturally.
    //
    // cimgui also ships `cimgui_impl.cpp` / `cimgui_impl.h` which
    // expose the Dear ImGui GLFW and Vulkan backends as C-ABI symbols
    // when `CIMGUI_USE_GLFW` and `CIMGUI_USE_VULKAN` are defined. So
    // we don't need a custom C++ shim like `src/wrapper/tinyobj/` —
    // the cimgui distribution itself is the shim.
    const cimgui_dep = b.dependency("cimgui", .{});
    const imgui_dep = b.dependency("imgui", .{});
    const imgui_tree = b.addWriteFiles();
    _ = imgui_tree.addCopyDirectory(cimgui_dep.path(""), "", .{});
    _ = imgui_tree.addCopyDirectory(imgui_dep.path(""), "imgui", .{});
    const imgui_root = imgui_tree.getDirectory();

    exe.root_module.addIncludePath(imgui_root);
    exe.root_module.addIncludePath(imgui_root.path(b, "imgui"));
    exe.root_module.addIncludePath(imgui_root.path(b, "imgui/backends"));
    // Tiny C-ABI shim that exposes a few Dear ImGui APIs the Zig
    // `@cImport` can't materialize (notably `ImGui::GetIO()` field
    // access — `ImGuiIO` references opaque types via `[*c]` pointers,
    // which Zig refuses to dereference). Compiled against the cimgui
    // include tree assembled just above.
    exe.root_module.addIncludePath(b.path("src/wrapper/imgui"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/wrapper/imgui/imgui_wrapper.cpp"),
        .flags = &.{
            "-std=c++17",
            "-fno-exceptions",
            "-fno-rtti",
            "-DCIMGUI_USE_GLFW",
            "-DCIMGUI_USE_VULKAN",
        },
    });

    exe.root_module.addCSourceFiles(.{
        .root = imgui_root,
        .files = &.{
            // cimgui itself: the auto-generated C-ABI wrapper around
            // every Dear ImGui function plus the backend bindings.
            "cimgui.cpp",
            "cimgui_impl.cpp",
            // Core Dear ImGui sources. `imgui_demo.cpp` is included so
            // the demo window is available for ad-hoc exploration.
            "imgui/imgui.cpp",
            "imgui/imgui_draw.cpp",
            "imgui/imgui_demo.cpp",
            "imgui/imgui_tables.cpp",
            "imgui/imgui_widgets.cpp",
            // Platform / renderer backends. Their C declarations come
            // out of `cimgui_impl.h` (which we read from Zig).
            "imgui/backends/imgui_impl_glfw.cpp",
            "imgui/backends/imgui_impl_vulkan.cpp",
        },
        .flags = &.{
            "-std=c++17",
            "-fno-exceptions",
            "-fno-rtti",
            "-DCIMGUI_USE_GLFW",
            "-DCIMGUI_USE_VULKAN",
            // Force the Dear ImGui backend functions
            // (`imgui_impl_glfw.cpp`, `imgui_impl_vulkan.cpp`) to be
            // declared and defined with C linkage so they match the
            // `extern "C"` declarations that cimgui_impl.h emits for
            // them. Otherwise the C++ compiler reports "different
            // language linkage" errors when cimgui_impl.cpp pulls in
            // both headers. Mirrors what the upstream cimgui CMake
            // build does.
            "-DIMGUI_IMPL_API=extern \"C\"",
            // `IMGUI_IMPL_API=extern "C"` also forces the *backend*
            // headers to use C linkage, which cannot tolerate the C++
            // function overload `ImGui_ImplVulkan_AddTexture(VkSampler,
            // VkImageView, VkImageLayout)` that Dear ImGui keeps around
            // as an obsolete shim. Disabling the obsolete-functions
            // block hides that second declaration entirely. The
            // current `ImGui_ImplVulkan_AddTexture(VkImageView,
            // VkImageLayout)` is still available.
            "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS",
        },
    });

    if (target.result.os.tag == .linux) {
        exe.root_module.linkSystemLibrary("gl", .{});
    }

    compileAllShaders(b, exe) catch |e| {
        std.debug.print("Failed to compile shaders: {}\n", .{e});
    };

    embedAllModels(b, exe) catch |e| {
        std.debug.print("Failed to embed models: {}\n", .{e});
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
