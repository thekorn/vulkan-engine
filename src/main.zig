const std = @import("std");
const c = @import("c.zig").c;

const Loop = @import("Loop.zig");
const Window = @import("Window.zig");
const Pipeline = @import("Pipeline.zig");

pub fn main() !void {
    var window = try Window.init(800, 600);
    defer window.deinit();

    var loop = try Loop.init(&window);
    defer loop.deinit();

    _ = try Pipeline.init(@embedFile("shader.frag.spv"), @embedFile("shader.vert.spv"));

    while (loop.is_running()) {
        c.glfwPollEvents();
    }
}
