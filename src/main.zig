const std = @import("std");

const c = @import("c.zig").c;
const Device = @import("Device.zig");
const Loop = @import("Loop.zig");
const Pipeline = @import("Pipeline.zig");
const Swapchain = @import("Swapchain.zig");
const Window = @import("Window.zig");
const Model = @import("Model.zig");
const checkSuccess = @import("utils.zig").checkSuccess;
const ArrayList = std.ArrayList;

const width = 800;
const height = 600;

fn createPipelineLayout(device: *Device, pipelineLayout: *c.VkPipelineLayout) !void {
    const pipelineLayoutInfo: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 0,
        .pSetLayouts = null,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
    };
    try checkSuccess(c.vkCreatePipelineLayout(device.globalDevice, &pipelineLayoutInfo, null, pipelineLayout));
}
fn createPipeline(device: *Device, swapChain: *Swapchain, pipelineLayout: *c.VkPipelineLayout, pipeline: *Pipeline) !void {
    var pipelineConfig = Pipeline.defaultPipelineConfigInfo(swapChain.width(), swapChain.height());
    pipelineConfig.renderPass = swapChain.renderPass;
    pipelineConfig.pipelineLayout = pipelineLayout.*;

    pipeline.* = try Pipeline.init(
        device,
        @embedFile("shader.frag.spv"),
        @embedFile("shader.vert.spv"),
        pipelineConfig,
    );
}
fn createCommandBuffers(
    alloc: std.mem.Allocator,
    commandBuffers: *ArrayList(c.VkCommandBuffer),
    swapChain: *Swapchain,
    device: *Device,
) !void {
    try commandBuffers.resize(alloc, swapChain.getImageCount());

    const allocInfo: c.VkCommandBufferAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandPool = device.commandPool,
        .commandBufferCount = @intCast(commandBuffers.items.len),
    };
    try checkSuccess(c.vkAllocateCommandBuffers(device.globalDevice, &allocInfo, commandBuffers.items.ptr));
}

fn drawFrame(alloc: std.mem.Allocator, swapChain: *Swapchain, commandBuffers: *ArrayList(c.VkCommandBuffer), pipeline: *Pipeline, window: *Window, device: *Device, pipelineLayout: *c.VkPipelineLayout, model: *Model) !void {
    var imageIndex: u32 = undefined;
    const result = try swapChain.acquireNextImage(&imageIndex);
    switch (result) {
        c.VK_ERROR_OUT_OF_DATE_KHR => {
            try recreateSwapChain(alloc, swapChain, window, device, pipeline, pipelineLayout);
        },
        c.VK_SUCCESS, c.VK_SUBOPTIMAL_KHR => {},
        else => return error.Unexpected,
    }
    try recordCommandBuffer(alloc, imageIndex, swapChain, commandBuffers, pipeline, model);
    const submitResult = try swapChain.submitCommandBuffers(&commandBuffers.items[imageIndex], &imageIndex);
    if (window.wasWindowResized()) {
        try recreateSwapChain(alloc, swapChain, window, device, pipeline, pipelineLayout);
        return;
    }
    switch (submitResult) {
        c.VK_ERROR_OUT_OF_DATE_KHR, c.VK_SUBOPTIMAL_KHR => {
            try recreateSwapChain(alloc, swapChain, window, device, pipeline, pipelineLayout);
            return;
        },
        c.VK_SUCCESS => {},
        else => return error.Unexpected,
    }
}

fn loadModels(device: *Device) !Model {
    const vertices = [_]Model.Vertex{
        Model.Vertex{ .position = .{ 0.0, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
        Model.Vertex{ .position = .{ 0.5, 0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
        Model.Vertex{ .position = .{ -0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
    };

    return try Model.init(device, vertices[0..]);
}

fn recreateSwapChain(alloc: std.mem.Allocator, swapChain: *Swapchain, window: *Window, device: *Device, pipeline: *Pipeline, pipelineLayout: *c.VkPipelineLayout) !void {
    var extend = window.getExtend();

    while (extend.width == 0 or extend.height == 0) {
        extend = window.getExtend();
        c.glfwWaitEvents();
    }

    try checkSuccess(c.vkDeviceWaitIdle(device.globalDevice));

    swapChain.* = try Swapchain.init(alloc, device, extend);
    try createPipeline(device, swapChain, pipelineLayout, pipeline);
}

fn recordCommandBuffer(alloc: std.mem.Allocator, imageIndex: usize, swapChain: *Swapchain, commandBuffers: *ArrayList(c.VkCommandBuffer), pipeline: *Pipeline, model: *Model) !void {
    const cmdBuf = commandBuffers.items[imageIndex];
    const beginInfo: c.VkCommandBufferBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    };
    try checkSuccess(c.vkBeginCommandBuffer(cmdBuf, &beginInfo));

    var clearValues: ArrayList(c.VkClearValue) = .empty;
    try clearValues.append(alloc, .{
        .color = .{
            .float32 = .{ 0.1, 0.1, 0.1, 1.0 },
        },
    });
    try clearValues.append(alloc, .{
        .depthStencil = .{ .depth = 1.0, .stencil = 0 },
    });

    const renderPassInfo: c.VkRenderPassBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = swapChain.renderPass,
        .framebuffer = swapChain.getFrameBuffer(imageIndex),
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = swapChain.swapChainExtent,
        },
        .clearValueCount = @intCast(clearValues.items.len),
        .pClearValues = clearValues.items.ptr,
    };
    c.vkCmdBeginRenderPass(cmdBuf, &renderPassInfo, c.VK_SUBPASS_CONTENTS_INLINE);
    pipeline.bind(cmdBuf);
    model.bind(cmdBuf);
    model.draw(cmdBuf);
    c.vkCmdEndRenderPass(cmdBuf);

    try checkSuccess(c.vkEndCommandBuffer(cmdBuf));
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    var commandBuffers: ArrayList(c.VkCommandBuffer) = .empty;
    defer commandBuffers.deinit(alloc);

    var window: Window = undefined;
    try window.init(width, height);
    defer window.deinit();

    var device = try Device.init(alloc, &window);
    defer device.deinit();

    var loop = try Loop.init(&window);
    defer loop.deinit();

    var pipeline = try alloc.create(Pipeline);
    defer pipeline.deinit();

    var swapChain = try Swapchain.init(alloc, &device, window.getExtend());
    defer swapChain.deinit();

    var model = try loadModels(&device);
    defer model.deinit();

    var pipelineLayout: c.VkPipelineLayout = undefined;
    try createPipelineLayout(&device, &pipelineLayout);
    defer c.vkDestroyPipelineLayout(device.globalDevice, pipelineLayout, null);

    try recreateSwapChain(alloc, &swapChain, &window, &device, pipeline, &pipelineLayout);
    try createCommandBuffers(alloc, &commandBuffers, &swapChain, &device);

    while (loop.is_running()) {
        c.glfwPollEvents();
        try drawFrame(alloc, &swapChain, &commandBuffers, pipeline, &window, &device, &pipelineLayout, &model);
    }

    // Wait for the device to become idle so the GPU isn't using any of
    // the resources we're about to tear down. Without this, the
    // validation layers (rightfully) complain on shutdown.
    _ = c.vkDeviceWaitIdle(device.globalDevice);
}

test {
    _ = @import("utils.zig");
    _ = @import("Vulkan.zig");
    _ = @import("Pipeline.zig");
    _ = @import("Window.zig");
    _ = @import("Swapchain.zig");
    _ = @import("Loop.zig");
    _ = @import("Model.zig");
}
