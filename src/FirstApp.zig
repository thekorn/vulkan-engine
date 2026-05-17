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

const Self = @This();

pub const width = 800;
pub const height = 600;

alloc: std.mem.Allocator,
// `window`, `device` and `pipeline` are stored as pointers because their
// `init` functions heap-allocate `Self` and own their own lifetime via
// `alloc.destroy(self)` in `deinit`. Holding them as stable pointers also
// guarantees that the back-pointers stored in sub-components (Device,
// Loop, Swapchain, Model) stay valid when `Self` is returned by value
// from this `init` and copied into the caller's storage.
window: *Window,
device: *Device,
loop: Loop,
pipeline: ?*Pipeline,
swapChain: Swapchain,
model: Model,
pipelineLayout: c.VkPipelineLayout,
commandBuffers: ArrayList(c.VkCommandBuffer),

pub fn init(alloc: std.mem.Allocator) !Self {
    const window = try Window.init(alloc, width, height);
    errdefer window.deinit();

    const device = try Device.init(alloc, window);
    errdefer device.deinit();

    var loop = try Loop.init(window);
    errdefer loop.deinit();

    var swapChain = try Swapchain.init(alloc, device, window.getExtent());
    errdefer swapChain.deinit();

    var self: Self = .{
        .alloc = alloc,
        .window = window,
        .device = device,
        .loop = loop,
        .pipeline = null,
        .swapChain = swapChain,
        .model = undefined,
        .pipelineLayout = undefined,
        .commandBuffers = .empty,
    };

    try self.loadModels();
    try self.createPipelineLayout();
    try self.recreateSwapChain();
    try self.createCommandBuffers();

    return self;
}

pub fn deinit(self: *Self) void {
    std.log.scoped(.firstApp).info("deinit first app", .{});
    self.commandBuffers.deinit(self.alloc);
    c.vkDestroyPipelineLayout(self.device.globalDevice, self.pipelineLayout, null);
    self.model.deinit();
    self.swapChain.deinit();
    if (self.pipeline) |p| p.deinit();
    self.loop.deinit();
    self.device.deinit();
    self.window.deinit();
}

pub fn run(self: *Self) !void {
    while (self.loop.is_running()) {
        c.glfwPollEvents();
        try self.drawFrame();
    }
    // Wait for the device to become idle so the GPU isn't using any of
    // the resources we're about to tear down. Without this, the
    // validation layers (rightfully) complain on shutdown.
    _ = c.vkDeviceWaitIdle(self.device.globalDevice);
}

fn createPipelineLayout(self: *Self) !void {
    const pipelineLayoutInfo: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 0,
        .pSetLayouts = null,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
    };
    try checkSuccess(c.vkCreatePipelineLayout(self.device.globalDevice, &pipelineLayoutInfo, null, &self.pipelineLayout));
}

fn createPipeline(self: *Self) !void {
    var pipelineConfig = Pipeline.defaultPipelineConfigInfo();
    pipelineConfig.renderPass = self.swapChain.renderPass;
    pipelineConfig.pipelineLayout = self.pipelineLayout;

    // Destroy any previously created pipeline (e.g. from a prior
    // swapchain recreation) so its shader modules and VkPipeline are
    // released; otherwise they leak until vkDestroyDevice and trigger
    // VUID-vkDestroyDevice-device-05137 validation errors.
    if (self.pipeline) |old| old.deinit();
    self.pipeline = null;

    self.pipeline = try Pipeline.init(
        self.alloc,
        self.device,
        @embedFile("shader.frag.spv"),
        @embedFile("shader.vert.spv"),
        pipelineConfig,
    );
}

fn createCommandBuffers(self: *Self) !void {
    try self.commandBuffers.resize(self.alloc, self.swapChain.getImageCount());

    const allocInfo: c.VkCommandBufferAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandPool = self.device.commandPool,
        .commandBufferCount = @intCast(self.commandBuffers.items.len),
    };
    try checkSuccess(c.vkAllocateCommandBuffers(self.device.globalDevice, &allocInfo, self.commandBuffers.items.ptr));
}

fn drawFrame(self: *Self) !void {
    var imageIndex: u32 = undefined;
    const result = try self.swapChain.acquireNextImage(&imageIndex);
    switch (result) {
        c.VK_ERROR_OUT_OF_DATE_KHR => {
            try self.recreateSwapChain();
            return;
        },
        c.VK_SUCCESS, c.VK_SUBOPTIMAL_KHR => {},
        else => return error.Unexpected,
    }
    try self.recordCommandBuffer(imageIndex);
    const submitResult = try self.swapChain.submitCommandBuffers(&self.commandBuffers.items[imageIndex], &imageIndex);
    if (self.window.wasWindowResized()) {
        self.window.resetWindowResized();
        try self.recreateSwapChain();
        return;
    }
    switch (submitResult) {
        c.VK_ERROR_OUT_OF_DATE_KHR, c.VK_SUBOPTIMAL_KHR => {
            try self.recreateSwapChain();
            return;
        },
        c.VK_SUCCESS => {},
        else => return error.Unexpected,
    }
}

fn loadModels(self: *Self) !void {
    const vertices = [_]Model.Vertex{
        Model.Vertex{ .position = .{ 0.0, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
        Model.Vertex{ .position = .{ 0.5, 0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
        Model.Vertex{ .position = .{ -0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
    };

    self.model = try Model.init(self.device, vertices[0..]);
}

fn recreateSwapChain(self: *Self) !void {
    var extent = self.window.getExtent();

    while (extent.width == 0 or extent.height == 0) {
        c.glfwWaitEvents();
        extent = self.window.getExtent();
    }

    const oldImageCount = self.swapChain.getImageCount();

    try checkSuccess(c.vkDeviceWaitIdle(self.device.globalDevice));

    // The previous swapchain still owns the surface; destroy it before
    // creating the new one. On MoltenVK, attempting to create a second
    // swapchain for the same surface while the old one is alive fails
    // with VK_ERROR_NATIVE_WINDOW_IN_USE_KHR (surfaced here as
    // error.Unexpected from vkCreateSwapchainKHR).
    self.swapChain.deinit();
    self.swapChain = try Swapchain.init(self.alloc, self.device, extent);
    try self.createPipeline();

    // we need to make sure that both are the same, otherwise the swapchain
    // images are not properly synchronized with the command buffers
    std.debug.assert(oldImageCount == self.swapChain.getImageCount());
}

fn recordCommandBuffer(self: *Self, imageIndex: u32) !void {
    const cmdBuf = self.commandBuffers.items[imageIndex];
    const beginInfo: c.VkCommandBufferBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    };
    try checkSuccess(c.vkBeginCommandBuffer(cmdBuf, &beginInfo));

    var clearValues: ArrayList(c.VkClearValue) = .empty;
    defer clearValues.deinit(self.alloc);
    try clearValues.append(self.alloc, .{
        .color = .{
            .float32 = .{ 0.1, 0.1, 0.1, 1.0 },
        },
    });
    try clearValues.append(self.alloc, .{
        .depthStencil = .{ .depth = 1.0, .stencil = 0 },
    });

    const renderPassInfo: c.VkRenderPassBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = self.swapChain.renderPass,
        .framebuffer = self.swapChain.getFrameBuffer(imageIndex),
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapChain.swapChainExtent,
        },
        .clearValueCount = @intCast(clearValues.items.len),
        .pClearValues = clearValues.items.ptr,
    };
    c.vkCmdBeginRenderPass(cmdBuf, &renderPassInfo, c.VK_SUBPASS_CONTENTS_INLINE);

    const viewport = c.VkViewport{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(self.swapChain.width()),
        .height = @floatFromInt(self.swapChain.height()),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };
    const scissor = c.VkRect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = self.swapChain.swapChainExtent,
    };
    c.vkCmdSetViewport(cmdBuf, 0, 1, &viewport);
    c.vkCmdSetScissor(cmdBuf, 0, 1, &scissor);

    self.pipeline.?.bind(cmdBuf);
    self.model.bind(cmdBuf);
    self.model.draw(cmdBuf);
    c.vkCmdEndRenderPass(cmdBuf);

    try checkSuccess(c.vkEndCommandBuffer(cmdBuf));
}
