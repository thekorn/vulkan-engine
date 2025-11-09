const std = @import("std");

fn addShader(b: *std.Build, exe: anytype, in_file: []const u8, out_file: []const u8) !void {
    // example:
    // glslc -o shaders/vert.spv shaders/shader.vert
    const full_in = try std.fs.path.join(b.allocator, &[_][]const u8{ "shaders", in_file });

    const run_cmd = b.addSystemCommand(&[_][]const u8{
        "glslc",
    });

    run_cmd.addArg("-o");

    const output = run_cmd.addOutputFileArg(out_file);

    run_cmd.addArg(full_in);
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

    //exe.linkLibC();
    exe.linkSystemLibrary("glfw");

    addShader(b, exe, "shader.vert", "vert.spv") catch |e| {
        std.debug.print("Failed to compile vertex shader: {}\n", .{e});
    };
    addShader(b, exe, "shader.frag", "frag.spv") catch |e| {
        std.debug.print("Failed to compile vertex shader: {}\n", .{e});
    };

    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
