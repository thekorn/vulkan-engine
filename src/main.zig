const std = @import("std");
const c = @import("c.zig").c;

const Loop = @import("Loop.zig");
const Window = @import("Window.zig");

pub fn main() !void {
    std.log.info("frag shader len: {d}", .{@embedFile("shader.frag.spv").len});
    std.log.info("vert shader len: {d}", .{@embedFile("shader.vert.spv").len});

    var window = try Window.init(800, 600);
    defer window.deinit();

    var loop = try Loop.init(&window);
    defer loop.deinit();

    while (loop.is_running()) {
        c.glfwPollEvents();
    }
}
