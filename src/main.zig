const std = @import("std");
const c = @import("c.zig").c;

const Loop = @import("Loop.zig");
const Window = @import("Window.zig");
const Pipeline = @import("Pipeline.zig");
const Device = @import("Device.zig");

const width = 800;
const height = 600;

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    var window = try Window.init(width, height);
    defer window.deinit();

    var device = try Device.init(alloc, &window);
    defer device.deinit();

    var loop = try Loop.init(&window);
    defer loop.deinit();

    var pipeline = try Pipeline.init(
        &device,
        @embedFile("shader.frag.spv"),
        @embedFile("shader.vert.spv"),
        Pipeline.defaultPipelineConfigInfo(width, height),
    );
    defer pipeline.deinit();

    while (loop.is_running()) {
        c.glfwPollEvents();
    }
}

test {
    _ = @import("utils.zig");
    _ = @import("Vulkan.zig");
    _ = @import("Pipeline.zig");
    _ = @import("Window.zig");
    _ = @import("Loop.zig");
}
