const std = @import("std");

const c = @import("c.zig").c;
const Device = @import("Device.zig");
const Loop = @import("Loop.zig");
const Pipeline = @import("Pipeline.zig");
const Swapchain = @import("Swapchain.zig");
const Window = @import("Window.zig");
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
fn createCommandBuffers(alloc: std.mem.Allocator, commandBuffers: *ArrayList(c.VkCommandBuffer), swapChain: *Swapchain, device: *Device, pipeline: *Pipeline) !void {
    //commandBuffers.resize(lveSwapChain.imageCount());

    try commandBuffers.resize(alloc, swapChain.getImageCount());
    //
    //VkCommandBufferAllocateInfo allocInfo{};
    //allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    //allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    //allocInfo.commandPool = lveDevice.getCommandPool();
    //allocInfo.commandBufferCount = static_cast<uint32_t>(commandBuffers.size());
    //
    const allocInfo: c.VkCommandBufferAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandPool = device.commandPool,
        .commandBufferCount = @intCast(commandBuffers.items.len),
    };
    //
    //if (vkAllocateCommandBuffers(lveDevice.device(), &allocInfo, commandBuffers.data()) !=
    //    VK_SUCCESS) {
    //  throw std::runtime_error("failed to allocate command buffers!");
    //}
    //
    try checkSuccess(c.vkAllocateCommandBuffers(device.globalDevice, &allocInfo, commandBuffers.items.ptr));
    //
    //for (int i = 0; i < commandBuffers.size(); i++) {
    //  VkCommandBufferBeginInfo beginInfo{};
    //  beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    //
    //  if (vkBeginCommandBuffer(commandBuffers[i], &beginInfo) != VK_SUCCESS) {
    //    throw std::runtime_error("failed to begin recording command buffer!");
    //  }
    //
    //  VkRenderPassBeginInfo renderPassInfo{};
    //  renderPassInfo.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    //  renderPassInfo.renderPass = lveSwapChain.getRenderPass();
    //  renderPassInfo.framebuffer = lveSwapChain.getFrameBuffer(i);
    //
    //  renderPassInfo.renderArea.offset = {0, 0};
    //  renderPassInfo.renderArea.extent = lveSwapChain.getSwapChainExtent();
    //
    //  std::array<VkClearValue, 2> clearValues{};
    //  clearValues[0].color = {0.1f, 0.1f, 0.1f, 1.0f};
    //  clearValues[1].depthStencil = {1.0f, 0};
    //  renderPassInfo.clearValueCount = static_cast<uint32_t>(clearValues.size());
    //  renderPassInfo.pClearValues = clearValues.data();
    //
    //  vkCmdBeginRenderPass(commandBuffers[i], &renderPassInfo, VK_SUBPASS_CONTENTS_INLINE);
    //
    //  lvePipeline->bind(commandBuffers[i]);
    //  vkCmdDraw(commandBuffers[i], 3, 1, 0, 0);
    //
    //  vkCmdEndRenderPass(commandBuffers[i]);
    //  if (vkEndCommandBuffer(commandBuffers[i]) != VK_SUCCESS) {
    //    throw std::runtime_error("failed to record command buffer!");
    //  }
    //}
    for (commandBuffers.items, 0..) |cmdBuf, i| {
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
            .framebuffer = swapChain.getFrameBuffer(i),
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = swapChain.swapChainExtent,
            },
            .clearValueCount = @intCast(clearValues.items.len),
            .pClearValues = clearValues.items.ptr,
        };
        c.vkCmdBeginRenderPass(cmdBuf, &renderPassInfo, c.VK_SUBPASS_CONTENTS_INLINE);
        pipeline.bind(cmdBuf);
        c.vkCmdDraw(cmdBuf, 3, 1, 0, 0);
        c.vkCmdEndRenderPass(cmdBuf);

        try checkSuccess(c.vkEndCommandBuffer(cmdBuf));
    }
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    var commandBuffers: ArrayList(c.VkCommandBuffer) = .empty;
    defer commandBuffers.deinit(alloc);

    var window = try Window.init(width, height);
    defer window.deinit();

    var device = try Device.init(alloc, &window);
    defer device.deinit();

    var loop = try Loop.init(&window);
    defer loop.deinit();

    var pipeline = try alloc.create(Pipeline);
    defer pipeline.deinit();

    var swapChain = try Swapchain.init(alloc, &device, &window);
    defer swapChain.deinit();

    var pipelineLayout: c.VkPipelineLayout = undefined;
    try createPipelineLayout(&device, &pipelineLayout);

    try createPipeline(&device, &swapChain, &pipelineLayout, pipeline);
    try createCommandBuffers(alloc, &commandBuffers, &swapChain, &device, pipeline);

    while (loop.is_running()) {
        c.glfwPollEvents();
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
}
