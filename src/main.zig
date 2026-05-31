const std = @import("std");

const FirstApp = @import("FirstApp.zig");

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    var app = try FirstApp.init(alloc);
    defer app.deinit();

    try app.run();
}

test {
    _ = @import("utils.zig");
    _ = @import("math.zig");
    _ = @import("Vulkan.zig");
    _ = @import("Pipeline.zig");
    _ = @import("Device.zig");
    _ = @import("Window.zig");
    _ = @import("Swapchain.zig");
    _ = @import("Loop.zig");
    _ = @import("Model.zig");
    _ = @import("Buffer.zig");
    _ = @import("Descriptors.zig");
    _ = @import("Texture.zig");
    _ = @import("Renderer.zig");
    _ = @import("systems/SimpleRenderSystem.zig");
    _ = @import("systems/PointLightSystem.zig");
    _ = @import("FrameInfo.zig");
    _ = @import("Camera.zig");
    _ = @import("GameObject.zig");
    _ = @import("KeyboardMovementController.zig");
    _ = @import("DebugUi.zig");
    _ = @import("FirstApp.zig");
}
