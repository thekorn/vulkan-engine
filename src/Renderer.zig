const std = @import("std");

const c = @import("c.zig").c;
const Device = @import("Device.zig");
const Swapchain = @import("Swapchain.zig");
const Window = @import("Window.zig");
const checkSuccess = @import("utils.zig").checkSuccess;
const ArrayList = std.ArrayList;

const Self = @This();

alloc: std.mem.Allocator,
window: *Window,
device: *Device,
swapChain: ?Swapchain,
commandBuffers: ArrayList(c.VkCommandBuffer),

currentImageIndex: u32 = 0,
currentFrameIndex: usize = 0,
isFrameStarted: bool = false,

pub fn init(alloc: std.mem.Allocator, window: *Window, device: *Device) !Self {
    var self: Self = .{
        .alloc = alloc,
        .window = window,
        .device = device,
        .swapChain = null,
        .commandBuffers = .empty,
    };

    try self.recreateSwapChain();
    try self.createCommandBuffers();

    return self;
}

pub fn deinit(self: *Self) void {
    self.freeCommandBuffers();
    if (self.swapChain) |*s| s.deinit();
}

pub fn getSwapChainRenderPass(self: *Self) c.VkRenderPass {
    return self.swapChain.?.renderPass;
}

pub fn isFrameInProgress(self: *const Self) bool {
    return self.isFrameStarted;
}

pub fn getCurrentCommandBuffer(self: *const Self) c.VkCommandBuffer {
    std.debug.assert(self.isFrameStarted);
    return self.commandBuffers.items[self.currentFrameIndex];
}

pub fn getFrameIndex(self: *const Self) usize {
    std.debug.assert(self.isFrameStarted);
    return self.currentFrameIndex;
}

pub fn beginFrame(self: *Self) !?c.VkCommandBuffer {
    std.debug.assert(!self.isFrameStarted);

    const result = try self.swapChain.?.acquireNextImage(&self.currentImageIndex);
    switch (result) {
        c.VK_ERROR_OUT_OF_DATE_KHR => {
            try self.recreateSwapChain();
            return null;
        },
        c.VK_SUCCESS, c.VK_SUBOPTIMAL_KHR => {},
        else => return error.Unexpected,
    }

    self.isFrameStarted = true;

    const commandBuffer = self.getCurrentCommandBuffer();
    const beginInfo: c.VkCommandBufferBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    };
    try checkSuccess(c.vkBeginCommandBuffer(commandBuffer, &beginInfo));
    return commandBuffer;
}

pub fn endFrame(self: *Self) !void {
    std.debug.assert(self.isFrameStarted);
    var commandBuffer = self.getCurrentCommandBuffer();
    try checkSuccess(c.vkEndCommandBuffer(commandBuffer));

    const submitResult = try self.swapChain.?.submitCommandBuffers(&commandBuffer, &self.currentImageIndex);
    if (submitResult == c.VK_ERROR_OUT_OF_DATE_KHR or
        submitResult == c.VK_SUBOPTIMAL_KHR or
        self.window.wasWindowResized())
    {
        self.window.resetWindowResized();
        try self.recreateSwapChain();
    } else if (submitResult != c.VK_SUCCESS) {
        return error.Unexpected;
    }

    self.isFrameStarted = false;
    self.currentFrameIndex = (self.currentFrameIndex + 1) % Swapchain.MAX_FRAMES_IN_FLIGHT;
}

pub fn beginSwapChainRenderPass(self: *Self, commandBuffer: c.VkCommandBuffer) !void {
    std.debug.assert(self.isFrameStarted);
    std.debug.assert(commandBuffer == self.getCurrentCommandBuffer());

    var swapchain = self.swapChain orelse unreachable;

    var clearValues: ArrayList(c.VkClearValue) = .empty;
    defer clearValues.deinit(self.alloc);
    try clearValues.append(self.alloc, .{
        .color = .{
            .float32 = .{ 0.01, 0.01, 0.01, 1.0 },
        },
    });
    try clearValues.append(self.alloc, .{
        .depthStencil = .{ .depth = 1.0, .stencil = 0 },
    });

    const renderPassInfo: c.VkRenderPassBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = swapchain.renderPass,
        .framebuffer = swapchain.getFrameBuffer(self.currentImageIndex),
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = swapchain.swapChainExtent,
        },
        .clearValueCount = @intCast(clearValues.items.len),
        .pClearValues = clearValues.items.ptr,
    };
    c.vkCmdBeginRenderPass(commandBuffer, &renderPassInfo, c.VK_SUBPASS_CONTENTS_INLINE);

    const viewport = c.VkViewport{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(swapchain.width()),
        .height = @floatFromInt(swapchain.height()),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };
    const scissor = c.VkRect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = swapchain.swapChainExtent,
    };
    c.vkCmdSetViewport(commandBuffer, 0, 1, &viewport);
    c.vkCmdSetScissor(commandBuffer, 0, 1, &scissor);
}

pub fn endSwapChainRenderPass(self: *Self, commandBuffer: c.VkCommandBuffer) void {
    std.debug.assert(self.isFrameStarted);
    std.debug.assert(commandBuffer == self.getCurrentCommandBuffer());
    c.vkCmdEndRenderPass(commandBuffer);
}

fn createCommandBuffers(self: *Self) !void {
    try self.commandBuffers.resize(self.alloc, Swapchain.MAX_FRAMES_IN_FLIGHT);

    const allocInfo: c.VkCommandBufferAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandPool = self.device.commandPool,
        .commandBufferCount = @intCast(self.commandBuffers.items.len),
    };
    try checkSuccess(c.vkAllocateCommandBuffers(self.device.globalDevice, &allocInfo, self.commandBuffers.items.ptr));
}

fn freeCommandBuffers(self: *Self) void {
    if (self.commandBuffers.items.len == 0) return;
    c.vkFreeCommandBuffers(
        self.device.globalDevice,
        self.device.commandPool,
        @intCast(self.commandBuffers.items.len),
        self.commandBuffers.items.ptr,
    );
    self.commandBuffers.clearAndFree(self.alloc);
}

fn recreateSwapChain(self: *Self) !void {
    var extent = self.window.getExtent();
    while (extent.width == 0 or extent.height == 0) {
        c.glfwWaitEvents();
        extent = self.window.getExtent();
    }
    try checkSuccess(c.vkDeviceWaitIdle(self.device.globalDevice));

    if (self.swapChain) |*sc| {
        // The previous swapchain still owns the surface; destroy it before
        // creating the new one. On MoltenVK, attempting to create a second
        // swapchain for the same surface while the old one is alive fails
        // with VK_ERROR_NATIVE_WINDOW_IN_USE_KHR.
        //
        // Save the old format values before deinit so we can compare them
        // against the newly-created swapchain. Format fields are plain
        // values and remain readable after Vulkan handles are released.
        const oldImageFormat = sc.swapChainImageFormat;
        const oldDepthFormat = sc.swapChainDepthFormat;

        sc.deinit();
        self.swapChain = try Swapchain.init(self.alloc, self.device, extent, sc);

        const new = self.swapChain orelse unreachable;
        if (oldImageFormat != new.swapChainImageFormat or
            oldDepthFormat != new.swapChainDepthFormat)
        {
            return error.SwapChainFormatChanged;
        }
    } else {
        self.swapChain = try Swapchain.init(self.alloc, self.device, extent, null);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Renderer has expected fields and types" {
    try std.testing.expectEqual(std.mem.Allocator, @FieldType(Self, "alloc"));
    try std.testing.expectEqual(*Window, @FieldType(Self, "window"));
    try std.testing.expectEqual(*Device, @FieldType(Self, "device"));
    try std.testing.expectEqual(?Swapchain, @FieldType(Self, "swapChain"));
    try std.testing.expectEqual(ArrayList(c.VkCommandBuffer), @FieldType(Self, "commandBuffers"));
    try std.testing.expectEqual(u32, @FieldType(Self, "currentImageIndex"));
    try std.testing.expectEqual(usize, @FieldType(Self, "currentFrameIndex"));
    try std.testing.expectEqual(bool, @FieldType(Self, "isFrameStarted"));
}

test "Renderer default frame state is not in progress" {
    var window: Window = undefined;
    var device: Device = undefined;
    const self: Self = .{
        .alloc = std.testing.allocator,
        .window = &window,
        .device = &device,
        .swapChain = null,
        .commandBuffers = .empty,
    };
    try std.testing.expect(!self.isFrameInProgress());
    try std.testing.expectEqual(@as(usize, 0), self.currentFrameIndex);
    try std.testing.expectEqual(@as(u32, 0), self.currentImageIndex);
}
