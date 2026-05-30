const std = @import("std");

const c = @import("c.zig").c;
const math = @import("math.zig");
const Camera = @import("Camera.zig");
const Device = @import("Device.zig");
const Pipeline = @import("Pipeline.zig");
const GameObject = @import("GameObject.zig");
const checkSuccess = @import("utils.zig").checkSuccess;

const Self = @This();

alloc: std.mem.Allocator,
device: *Device,
pipeline: ?*Pipeline,
pipelineLayout: c.VkPipelineLayout,

pub const SimplePushConstantData = extern struct {
    transform: math.Mat4 = math.identity_mat4,
    color: math.Vec3 align(16) = .{ 0, 0, 0 },
};

pub fn init(alloc: std.mem.Allocator, device: *Device, renderPass: c.VkRenderPass) !Self {
    var self: Self = .{
        .alloc = alloc,
        .device = device,
        .pipeline = null,
        .pipelineLayout = undefined,
    };

    try self.createPipelineLayout();
    errdefer c.vkDestroyPipelineLayout(self.device.globalDevice, self.pipelineLayout, null);

    try self.createPipeline(renderPass);

    return self;
}

pub fn deinit(self: *Self) void {
    if (self.pipeline) |p| p.deinit();
    c.vkDestroyPipelineLayout(self.device.globalDevice, self.pipelineLayout, null);
}

fn createPipelineLayout(self: *Self) !void {
    const pushConstantRange: c.VkPushConstantRange = .{
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .offset = 0,
        .size = @sizeOf(SimplePushConstantData),
    };

    const pipelineLayoutInfo: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 0,
        .pSetLayouts = null,
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

pub fn renderGameObjects(
    self: *Self,
    commandBuffer: c.VkCommandBuffer,
    gameObjects: []GameObject,
    camera: *const Camera,
) !void {
    self.pipeline.?.bind(commandBuffer);
    const projectionView = math.mul4(camera.getProjection(), camera.getView());
    for (gameObjects) |*obj| {
        // Skip model-less objects (e.g. the camera viewer object that
        // only carries a transform component).
        if (obj.model == null) continue;

        const transform = math.mul4(projectionView, obj.transform.mat4());

        const push: SimplePushConstantData = .{
            .color = obj.color,
            .transform = transform,
        };

        c.vkCmdPushConstants(
            commandBuffer,
            self.pipelineLayout,
            c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            0,
            @sizeOf(SimplePushConstantData),
            &push,
        );
        obj.model.?.bind(commandBuffer);
        obj.model.?.draw(commandBuffer);
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
    try std.testing.expectEqualStrings("transform", fields[0].name);
    try std.testing.expectEqual(math.Mat4, fields[0].type);
    try std.testing.expectEqualStrings("color", fields[1].name);
    try std.testing.expectEqual(math.Vec3, fields[1].type);
}

test "SimplePushConstantData defaults transform to the identity matrix" {
    const p: SimplePushConstantData = .{};
    inline for (0..4) |col| {
        inline for (0..4) |row| {
            const expected: f32 = if (col == row) 1.0 else 0.0;
            try std.testing.expectEqual(expected, p.transform[col][row]);
        }
    }
}

test "SimplePushConstantData color is 16-byte aligned (for std140 push constants)" {
    try std.testing.expect(@offsetOf(SimplePushConstantData, "color") % 16 == 0);
}

test "SimplePushConstantData transform is at offset 0 (matches push-constant range)" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(SimplePushConstantData, "transform"));
}

test "SimplePushConstantData size fits in the Vulkan-mandated minimum (128 bytes)" {
    // The Vulkan spec guarantees maxPushConstantsSize >= 128 bytes; the
    // single range we register covers the whole struct, so it must not
    // exceed that minimum to remain portable.
    try std.testing.expect(@sizeOf(SimplePushConstantData) <= 128);
}

test "SimplePushConstantData default color is zero-initialized" {
    const p: SimplePushConstantData = .{};
    try std.testing.expectEqual(@as(f32, 0.0), p.color[0]);
    try std.testing.expectEqual(@as(f32, 0.0), p.color[1]);
    try std.testing.expectEqual(@as(f32, 0.0), p.color[2]);
}
