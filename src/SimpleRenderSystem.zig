const std = @import("std");

const c = @import("c.zig").c;
const cglm = @import("c.zig").cglm;
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
    // TODO: should be cglm.GLM_MAT2_IDENTITY
    transform: cglm.mat2 = .{ .{ 1.0, 0.0 }, .{ 0.0, 1.0 } },
    offset: cglm.vec2,
    color: cglm.vec3 align(16),
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

pub fn renderGameObjects(self: *Self, commandBuffer: c.VkCommandBuffer, gameObjects: []GameObject) !void {
    // update rotation
    var i: u64 = 0;
    for (gameObjects) |*obj| {
        i += 1;
        obj.transform2d.rotation = @floatCast(@mod(
            obj.transform2d.rotation + 0.001 * @as(f32, @floatFromInt(i)),
            2 * std.math.pi,
        ));
    }

    self.pipeline.?.bind(commandBuffer);
    for (gameObjects) |*obj| {
        const push: SimplePushConstantData = .{
            .offset = obj.transform2d.translation,
            .color = obj.color,
            .transform = obj.transform2d.mat2(),
        };

        c.vkCmdPushConstants(
            commandBuffer,
            self.pipelineLayout,
            c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            0,
            @sizeOf(SimplePushConstantData),
            &push,
        );
        obj.model.bind(commandBuffer);
        obj.model.draw(commandBuffer);
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
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("transform", fields[0].name);
    try std.testing.expectEqual(cglm.mat2, fields[0].type);
    try std.testing.expectEqualStrings("offset", fields[1].name);
    try std.testing.expectEqual(cglm.vec2, fields[1].type);
    try std.testing.expectEqualStrings("color", fields[2].name);
    try std.testing.expectEqual(cglm.vec3, fields[2].type);
}

test "SimplePushConstantData defaults transform to the identity matrix" {
    const p: SimplePushConstantData = .{
        .offset = .{ 0, 0 },
        .color = .{ 0, 0, 0 },
    };
    try std.testing.expectEqual(@as(f32, 1.0), p.transform[0][0]);
    try std.testing.expectEqual(@as(f32, 0.0), p.transform[0][1]);
    try std.testing.expectEqual(@as(f32, 0.0), p.transform[1][0]);
    try std.testing.expectEqual(@as(f32, 1.0), p.transform[1][1]);
}

test "SimplePushConstantData color is 16-byte aligned (for std140 push constants)" {
    try std.testing.expect(@offsetOf(SimplePushConstantData, "color") % 16 == 0);
    try std.testing.expect(@offsetOf(SimplePushConstantData, "color") >= @offsetOf(SimplePushConstantData, "offset"));
}
