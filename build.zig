const std = @import("std");
const zlinter = @import("zlinter");

const shaders_dir = "./shaders";
const models_dir = "./models";
const textures_dir = "./textures";

fn compileAllShaders(b: *std.Build, exe: anytype) !void {
    const io = b.graph.io;
    var dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, shaders_dir, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(b.allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        const out_file = try b.allocator.print("{s}.spv", .{entry.path});
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
    const full_in = try std.Io.Dir.path.join(b.allocator, &[_][]const u8{ shaders_dir, in_file });

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

        const full_path = try std.Io.Dir.path.join(b.allocator, &[_][]const u8{ models_dir, entry.path });
        std.debug.print("embedding model: {s}\n", .{full_path});
        exe.root_module.addAnonymousImport(entry.path, .{
            .root_source_file = b.path(full_path),
        });
    }
}

/// Walk `textures/` and expose each asset file (e.g. `.ktx`) to the
/// executable as an anonymous module import keyed by the file's basename
/// (e.g. `stonefloor01_color_rgba.ktx`), so call sites can use
/// `@embedFile("stonefloor01_color_rgba.ktx")`. Mirrors `embedAllModels`
/// — see that helper for the directory-discovery convention.
fn embedAllTextures(b: *std.Build, exe: anytype) !void {
    const io = b.graph.io;
    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, textures_dir, .{ .iterate = true }) catch |err| switch (err) {
        // Tolerate a missing `textures/` directory so the project still
        // builds before any asset has been added.
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(b.allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        const full_path = try std.Io.Dir.path.join(b.allocator, &[_][]const u8{ textures_dir, entry.path });
        std.debug.print("embedding texture: {s}\n", .{full_path});
        exe.root_module.addAnonymousImport(entry.path, .{
            .root_source_file = b.path(full_path),
        });
    }
}

pub fn build(b: *std.Build) void {
    const default_target: std.Target.Query = if (b.graph.environ_map.get("NIX_DYNAMIC_LINKER")) |dynamic_linker|
        if (dynamic_linker.len == 0)
            .{}
        else
            std.Target.Query.parse(.{
                .arch_os_abi = b.graph.environ_map.get("NIX_ZIG_TARGET") orelse "native",
                .dynamic_linker = dynamic_linker,
            }) catch @panic("invalid NIX_DYNAMIC_LINKER")
    else
        .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    // Select which application root `main.zig` runs. Use
    // `zig build run -Dapp=tutorial` for the full 3D scene or
    // `-Dapp=custom` (the default) for the minimal immediate-mode UI.
    const App = enum { custom, tutorial };
    const app = b.option(
        App,
        "app",
        "Which application to run: custom (immediate-mode UI, default) or tutorial (full 3D scene)",
    ) orelse .custom;
    const build_options = b.addOptions();
    build_options.addOption(App, "app", app);

    const exe = b.addExecutable(.{
        .name = "vulkan_engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (target.result.os.tag == .linux and target.query.dynamic_linker != null) {
        // Nix's shared libraries resolve versioned glibc symbols at runtime.
        exe.linker_allow_shlib_undefined = true;
    }

    exe.root_module.addOptions("build_options", build_options);

    exe.root_module.linkSystemLibrary("glfw3", .{});
    exe.root_module.linkSystemLibrary("vulkan", .{});

    if (target.result.os.tag == .macos) {
        if (b.graph.environ_map.get("SDKROOT")) |sdkroot| {
            exe.root_module.addSystemFrameworkPath(.{
                .cwd_relative = b.pathJoin(&.{ sdkroot, "System/Library/Frameworks" }),
            });
        }
    }

    // The OBJ loader is a thin C-ABI wrapper around the C++
    // tinyobjloader library. Compiling the wrapper requires libc++ and
    // libc; pulling in tinyobjloader via `linkSystemLibrary` lets
    // pkg-config wire up its include path and static archive.
    exe.root_module.link_libc = true;
    exe.root_module.link_libcpp = true;
    exe.root_module.addIncludePath(b.path("src/wrapper/tinyobj"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/wrapper/tinyobj/tinyobj_wrapper.cpp"),
        // zcov instruments Zig code. Keep fuzz-mode sanitizer coverage
        // out of C++: its trace callbacks and PC tables use a different ABI.
        .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-sanitize-coverage=trace-cmp,inline-8bit-counters,pc-table" },
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

    const c_header = b.addWriteFiles().add("vulkan_engine_c.h",
        \\#include <GLFW/glfw3.h>
        \\#include <vulkan/vulkan_beta.h>
        \\#include <stdarg.h>
        \\#include <stdbool.h>
        \\#include <stdio.h>
        \\#include <stdint.h>
        \\#include "tinyobj_wrapper.h"
        \\#define __attribute__(x)
        \\#include "cimgui.h"
        \\#include "cimgui_impl.h"
        \\#undef __attribute__
        \\#include "imgui_wrapper.h"
    );
    const translate_c = b.addTranslateC(.{
        .root_source_file = c_header,
        .target = target,
        .optimize = optimize,
    });
    translate_c.linkSystemLibrary("glfw3", .{});
    translate_c.linkSystemLibrary("vulkan", .{});
    translate_c.addIncludePath(b.path("src/wrapper/tinyobj"));
    translate_c.addIncludePath(b.path("src/wrapper/imgui"));
    translate_c.addIncludePath(imgui_root);
    translate_c.addIncludePath(imgui_root.path(b, "imgui"));
    translate_c.addIncludePath(imgui_root.path(b, "imgui/backends"));
    translate_c.defineCMacro("GLFW_INCLUDE_VULKAN", null);
    translate_c.defineCMacro("GLFW_INCLUDE_NONE", null);
    translate_c.defineCMacro("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", null);
    translate_c.defineCMacro("CIMGUI_USE_GLFW", null);
    translate_c.defineCMacro("CIMGUI_USE_VULKAN", null);
    translate_c.defineCMacro("IMGUI_DISABLE_OBSOLETE_FUNCTIONS", null);
    exe.root_module.addImport("c", translate_c.createModule());

    exe.root_module.addIncludePath(imgui_root);
    exe.root_module.addIncludePath(imgui_root.path(b, "imgui"));
    exe.root_module.addIncludePath(imgui_root.path(b, "imgui/backends"));
    // Tiny C-ABI shim that exposes a few Dear ImGui APIs the Zig C
    // translator can't materialize (notably `ImGui::GetIO()` field
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
            "-fno-sanitize-coverage=trace-cmp,inline-8bit-counters,pc-table",
            "-DCIMGUI_USE_GLFW",
            "-DCIMGUI_USE_VULKAN",
            "-DGLFW_INCLUDE_NONE",
            "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS",
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
            "imgui/backends/imgui_impl_vulkan.cpp",
        },
        .flags = &.{
            "-std=c++17",
            "-fno-exceptions",
            "-fno-rtti",
            "-fno-sanitize-coverage=trace-cmp,inline-8bit-counters,pc-table",
            "-DCIMGUI_USE_GLFW",
            "-DCIMGUI_USE_VULKAN",
            "-DGLFW_INCLUDE_NONE",
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

    exe.root_module.addCSourceFile(.{
        .file = b.path("src/wrapper/imgui/imgui_impl_glfw_nix.cpp"),
        .flags = &.{
            "-std=c++17",
            "-fno-exceptions",
            "-fno-rtti",
            "-fno-sanitize-coverage=trace-cmp,inline-8bit-counters,pc-table",
            "-DCIMGUI_USE_GLFW",
            "-DCIMGUI_USE_VULKAN",
            "-DGLFW_INCLUDE_NONE",
            "-DGLFW_NATIVE_INCLUDE_NONE",
            "-DIMGUI_IMPL_API=extern \"C\"",
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

    embedAllTextures(b, exe) catch |e| {
        std.debug.print("Failed to embed textures: {}\n", .{e});
    };

    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const coverage = b.option(bool, "coverage", "Enable zig-cov") orelse false;
    const coverage_rt = b.option([]const u8, "coverage-rt", "zig-cov-rt path") orelse null;

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        // Zig's fuzz instrumentation requires the compiler-provided runner.
        // Keep the project's friendlier runner for ordinary test invocations.
        .test_runner = if (coverage) null else .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    if (target.result.os.tag == .linux and target.query.dynamic_linker != null) {
        exe_tests.linker_allow_shlib_undefined = true;
    }
    if (coverage) {
        exe_tests.use_llvm = true;
        exe_tests.root_module.fuzz = true;
        exe_tests.root_module.link_libc = true;
        if (coverage_rt) |path| {
            exe_tests.root_module.addObjectFile(.{ .cwd_relative = path });
        }
    }

    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    const lint_step = b.step("lint", "Lint source code");
    lint_step.dependOn(step: {
        var builder = zlinter.builder(b, .{});
        builder.addRule(.{ .builtin = .switch_case_ordering }, .{});
        builder.addRule(.{ .builtin = .no_unused }, .{});
        builder.addRule(.{ .builtin = .no_deprecated }, .{});
        builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{});
        break :step builder.build();
    });
}
