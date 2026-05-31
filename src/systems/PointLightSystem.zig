//! Render system that draws a single point-light "billboard" — a
//! camera-facing quad (six vertices) whose position, color and
//! intensity come from the per-frame global UBO. Mirrors
//! `PointLightSystem` from the upstream Little Vulkan Engine tutorial
//! (see `systems/point_light_system.cpp`).
//!
//! The pipeline takes no vertex buffers; the vertex shader uses
//! `gl_VertexIndex` together with a constant lookup table to emit the
//! six vertices of a screen-aligned quad and pulls the world-space
//! light position out of the UBO.

const std = @import("std");

const c = @import("../c.zig").c;
const Device = @import("../Device.zig");
const FrameInfo = @import("../FrameInfo.zig");
const Pipeline = @import("../Pipeline.zig");
const checkSuccess = @import("../utils.zig").checkSuccess;

const Self = @This();

alloc: std.mem.Allocator,
device: *Device,
pipeline: ?*Pipeline,
pipelineLayout: c.VkPipelineLayout,

pub fn init(
    alloc: std.mem.Allocator,
    device: *Device,
    renderPass: c.VkRenderPass,
    globalSetLayout: c.VkDescriptorSetLayout,
) !Self {
    var self: Self = .{
        .alloc = alloc,
        .device = device,
        .pipeline = null,
        // SAFETY: written by createPipelineLayout immediately below before any read.
        .pipelineLayout = undefined,
    };

    try self.createPipelineLayout(globalSetLayout);
    errdefer c.vkDestroyPipelineLayout(self.device.globalDevice, self.pipelineLayout, null);

    try self.createPipeline(renderPass);

    return self;
}

pub fn deinit(self: *Self) void {
    if (self.pipeline) |p| p.deinit();
    c.vkDestroyPipelineLayout(self.device.globalDevice, self.pipelineLayout, null);
}

fn createPipelineLayout(self: *Self, globalSetLayout: c.VkDescriptorSetLayout) !void {
    // No push constants for the point-light system — every per-frame
    // value the shader needs (light position, color, intensity) comes
    // from the global UBO.
    const descriptorSetLayouts = [_]c.VkDescriptorSetLayout{globalSetLayout};

    const pipelineLayoutInfo: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = @intCast(descriptorSetLayouts.len),
        .pSetLayouts = &descriptorSetLayouts,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
    };
    try checkSuccess(c.vkCreatePipelineLayout(
        self.device.globalDevice,
        &pipelineLayoutInfo,
        null,
        &self.pipelineLayout,
    ));
}

fn createPipeline(self: *Self, renderPass: c.VkRenderPass) !void {
    std.debug.assert(self.pipelineLayout != null);

    var pipelineConfig = Pipeline.defaultPipelineConfigInfo();
    // The point-light vertex shader generates its vertices procedurally
    // from `gl_VertexIndex`, so there's no vertex buffer bound.
    pipelineConfig.bindingDescriptions = &.{};
    pipelineConfig.attributeDescriptions = &.{};
    pipelineConfig.renderPass = renderPass;
    pipelineConfig.pipelineLayout = self.pipelineLayout;

    self.pipeline = try Pipeline.init(
        self.alloc,
        self.device,
        @embedFile("point_light.frag.spv"),
        @embedFile("point_light.vert.spv"),
        pipelineConfig,
    );
}

pub fn render(self: *Self, frameInfo: *FrameInfo) void {
    self.pipeline.?.bind(frameInfo.commandBuffer);

    c.vkCmdBindDescriptorSets(
        frameInfo.commandBuffer,
        c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        self.pipelineLayout,
        0,
        1,
        &frameInfo.globalDescriptorSet,
        0,
        null,
    );

    // Six vertices, one instance — the vertex shader picks the quad
    // corners from `OFFSETS[gl_VertexIndex]`.
    c.vkCmdDraw(frameInfo.commandBuffer, 6, 1, 0, 0);
}

test "PointLightSystem has expected fields and types" {
    const fields = @typeInfo(Self).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 4), fields.len);
    try std.testing.expectEqual(std.mem.Allocator, @FieldType(Self, "alloc"));
    try std.testing.expectEqual(*Device, @FieldType(Self, "device"));
    try std.testing.expectEqual(?*Pipeline, @FieldType(Self, "pipeline"));
    try std.testing.expectEqual(c.VkPipelineLayout, @FieldType(Self, "pipelineLayout"));
}
