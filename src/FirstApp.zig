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
pipeline: *Pipeline,
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

    var swapChain = try Swapchain.init(alloc, device, window);
    errdefer swapChain.deinit();

    var self: Self = .{
        .alloc = alloc,
        .window = window,
        .device = device,
        .loop = loop,
        .pipeline = undefined,
        .swapChain = swapChain,
        .model = undefined,
        .pipelineLayout = undefined,
        .commandBuffers = .empty,
    };

    try self.loadModels();
    try self.createPipelineLayout();
    try self.createPipeline();
    try self.createCommandBuffers();

    return self;
}

pub fn deinit(self: *Self) void {
    self.commandBuffers.deinit(self.alloc);
    c.vkDestroyPipelineLayout(self.device.globalDevice, self.pipelineLayout, null);
    self.model.deinit();
    self.swapChain.deinit();
    self.pipeline.deinit();
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
    var pipelineConfig = Pipeline.defaultPipelineConfigInfo(self.swapChain.width(), self.swapChain.height());
    pipelineConfig.renderPass = self.swapChain.renderPass;
    pipelineConfig.pipelineLayout = self.pipelineLayout;

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

    for (self.commandBuffers.items, 0..) |cmdBuf, i| {
        const beginInfo: c.VkCommandBufferBeginInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        };
        try checkSuccess(c.vkBeginCommandBuffer(cmdBuf, &beginInfo));

        var clearValues: ArrayList(c.VkClearValue) = .empty;
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
            .framebuffer = self.swapChain.getFrameBuffer(i),
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = self.swapChain.swapChainExtent,
            },
            .clearValueCount = @intCast(clearValues.items.len),
            .pClearValues = clearValues.items.ptr,
        };
        c.vkCmdBeginRenderPass(cmdBuf, &renderPassInfo, c.VK_SUBPASS_CONTENTS_INLINE);
        self.pipeline.bind(cmdBuf);
        self.model.bind(cmdBuf);
        self.model.draw(cmdBuf);
        c.vkCmdEndRenderPass(cmdBuf);

        try checkSuccess(c.vkEndCommandBuffer(cmdBuf));
    }
}

fn drawFrame(self: *Self) !void {
    var imageIndex: u32 = undefined;
    const result = try self.swapChain.acquireNextImage(&imageIndex);
    switch (result) {
        c.VK_SUCCESS, c.VK_SUBOPTIMAL_KHR => {},
        else => return error.Unexpected,
    }
    try checkSuccess(try self.swapChain.submitCommandBuffers(&self.commandBuffers.items[imageIndex], &imageIndex));
}

fn loadModels(self: *Self) !void {
    const vertices = [_]Model.Vertex{
        Model.Vertex{ .position = .{ 0.0, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
        Model.Vertex{ .position = .{ 0.5, 0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
        Model.Vertex{ .position = .{ -0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
    };

    self.model = try Model.init(self.device, vertices[0..]);
}
