const std = @import("std");

const c = @import("../c.zig").c;
const math = @import("../math.zig");
const Device = @import("../Device.zig");
const FrameInfo = @import("../FrameInfo.zig");
const Pipeline = @import("../Pipeline.zig");
const checkSuccess = @import("../utils.zig").checkSuccess;

const Self = @This();

alloc: std.mem.Allocator,
device: *Device,
pipeline: ?*Pipeline,
pipelineLayout: c.VkPipelineLayout,

pub const SimplePushConstantData = extern struct {
    /// Per-object model-to-world matrix. The shader multiplies this by
    /// `ubo.projection * ubo.view` to get the final clip-space transform.
    modelMatrix: math.Mat4 = math.identity_mat4,
    // `normalMatrix` is stored as a `Mat4` (rather than a `Mat3`) so
    // that the std140 push-constant layout matches the GLSL side
    // without needing per-column padding. The shader extracts it as
    // `mat3(push.normalMatrix)`.
    normalMatrix: math.Mat4 = math.identity_mat4,
};

pub fn init(
    alloc: std.mem.Allocator,
    device: *Device,
    renderPass: c.VkRenderPass,
    globalSetLayout: c.VkDescriptorSetLayout,
    /// Per-object material descriptor set layout bound at `set = 1`
    /// (one `COMBINED_IMAGE_SAMPLER` for `diffuseMap` in `shader.frag`).
    textureSetLayout: c.VkDescriptorSetLayout,
) !Self {
    var self: Self = .{
        .alloc = alloc,
        .device = device,
        .pipeline = null,
        // SAFETY: written by createPipelineLayout immediately below before any read.
        .pipelineLayout = undefined,
    };

    try self.createPipelineLayout(globalSetLayout, textureSetLayout);
    errdefer c.vkDestroyPipelineLayout(self.device.globalDevice, self.pipelineLayout, null);

    try self.createPipeline(renderPass);

    return self;
}

pub fn deinit(self: *Self) void {
    if (self.pipeline) |p| p.deinit();
    c.vkDestroyPipelineLayout(self.device.globalDevice, self.pipelineLayout, null);
}

fn createPipelineLayout(
    self: *Self,
    globalSetLayout: c.VkDescriptorSetLayout,
    textureSetLayout: c.VkDescriptorSetLayout,
) !void {
    const pushConstantRange: c.VkPushConstantRange = .{
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .offset = 0,
        .size = @sizeOf(SimplePushConstantData),
    };

    // Two descriptor sets: the per-frame global UBO at `set = 0`
    // (camera + lights) and a per-object material texture at
    // `set = 1`. The texture set is bound inside `renderGameObjects`
    // from each `GameObject.textureDescriptorSet`.
    const descriptorSetLayouts = [_]c.VkDescriptorSetLayout{
        globalSetLayout,
        textureSetLayout,
    };

    const pipelineLayoutInfo: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = @intCast(descriptorSetLayouts.len),
        .pSetLayouts = &descriptorSetLayouts,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &pushConstantRange,
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
    pipelineConfig.renderPass = renderPass;
    pipelineConfig.pipelineLayout = self.pipelineLayout;

    self.pipeline = try Pipeline.init(
        self.alloc,
        self.device,
        @embedFile("shader.frag.spv"),
        @embedFile("shader.vert.spv"),
        pipelineConfig,
    );
}

pub fn renderGameObjects(self: *Self, frameInfo: *FrameInfo) !void {
    self.pipeline.?.bind(frameInfo.commandBuffer);

    // Bind the global descriptor set (set = 0) once for this draw
    // pass; every object uses the same projection-view + light data.
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

    // Iterate the scene's `GameObject.Map` (matches the upstream
    // `std::unordered_map` iteration). Order is unspecified, but
    // depth testing is enabled on the pipeline so the visible result
    // is invariant for opaque geometry.
    var it = frameInfo.gameObjects.valueIterator();
    while (it.next()) |obj| {
        // Skip model-less objects (e.g. the camera viewer object that
        // only carries a transform component).
        if (obj.model == null) continue;

        // Per-object material texture (`set = 1`). `FirstApp.run`
        // wires up either the named texture's descriptor set or the
        // 1×1 white fallback for every renderable object, so a null
        // handle here is a setup bug — assert loudly.
        std.debug.assert(obj.textureDescriptorSet != null);
        c.vkCmdBindDescriptorSets(
            frameInfo.commandBuffer,
            c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.pipelineLayout,
            1,
            1,
            &obj.textureDescriptorSet,
            0,
            null,
        );

        const push: SimplePushConstantData = .{
            .modelMatrix = obj.transform.mat4(),
            .normalMatrix = obj.transform.normalMatrix(),
        };

        c.vkCmdPushConstants(
            frameInfo.commandBuffer,
            self.pipelineLayout,
            c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            0,
            @sizeOf(SimplePushConstantData),
            &push,
        );
        obj.model.?.bind(frameInfo.commandBuffer);
        obj.model.?.draw(frameInfo.commandBuffer);
    }
}

test "SimpleRenderSystem has expected fields and types" {
    try std.testing.expectEqual(std.mem.Allocator, @FieldType(Self, "alloc"));
    try std.testing.expectEqual(*Device, @FieldType(Self, "device"));
    try std.testing.expectEqual(?*Pipeline, @FieldType(Self, "pipeline"));
    try std.testing.expectEqual(c.VkPipelineLayout, @FieldType(Self, "pipelineLayout"));
}

test "SimplePushConstantData has the expected field layout" {
    const fields = @typeInfo(SimplePushConstantData).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("modelMatrix", fields[0].name);
    try std.testing.expectEqual(math.Mat4, fields[0].type);
    try std.testing.expectEqualStrings("normalMatrix", fields[1].name);
    try std.testing.expectEqual(math.Mat4, fields[1].type);
}

test "SimplePushConstantData defaults modelMatrix to the identity matrix" {
    const p: SimplePushConstantData = .{};
    inline for (0..4) |col| {
        inline for (0..4) |row| {
            const expected: f32 = if (col == row) 1.0 else 0.0;
            try std.testing.expectEqual(expected, p.modelMatrix[col][row]);
        }
    }
}

test "SimplePushConstantData normalMatrix is 16-byte aligned (for std140 push constants)" {
    try std.testing.expect(@offsetOf(SimplePushConstantData, "normalMatrix") % 16 == 0);
}

test "SimplePushConstantData modelMatrix is at offset 0 (matches push-constant range)" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(SimplePushConstantData, "modelMatrix"));
}

test "SimplePushConstantData size fits in the Vulkan-mandated minimum (128 bytes)" {
    // The Vulkan spec guarantees maxPushConstantsSize >= 128 bytes; the
    // single range we register covers the whole struct, so it must not
    // exceed that minimum to remain portable.
    try std.testing.expect(@sizeOf(SimplePushConstantData) <= 128);
}

test "SimplePushConstantData defaults normalMatrix to the identity matrix" {
    const p: SimplePushConstantData = .{};
    inline for (0..4) |col| {
        inline for (0..4) |row| {
            const expected: f32 = if (col == row) 1.0 else 0.0;
            try std.testing.expectEqual(expected, p.normalMatrix[col][row]);
        }
    }
}
