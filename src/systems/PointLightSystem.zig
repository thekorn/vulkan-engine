//! Render system that draws each point-light `GameObject` as a small
//! camera-facing billboard. Mirrors `PointLightSystem` from the
//! upstream Little Vulkan Engine tutorial (see
//! `systems/point_light_system.cpp`).
//!
//! The pipeline takes no vertex buffers; the vertex shader uses
//! `gl_VertexIndex` together with a constant lookup table to emit the
//! six vertices of a screen-aligned quad. Per-light position, color
//! and radius are uploaded via push constants (the per-light radius
//! comes from `GameObject.transform.scale[0]`, matching the upstream
//! convention).
//!
//! `update()` walks the scene's `GameObject.Map` once per frame,
//! rotates each point light around the world's Y axis (matching the
//! upstream "demo" animation) and copies the visible lights into the
//! global UBO so the simple render system's fragment shader can use
//! them for diffuse lighting.

const std = @import("std");

const c = @import("../c.zig").c;
const math = @import("../math.zig");
const Device = @import("../Device.zig");
const FrameInfo = @import("../FrameInfo.zig");
const GameObject = @import("../GameObject.zig");
const Pipeline = @import("../Pipeline.zig");
const checkSuccess = @import("../utils.zig").checkSuccess;

const Self = @This();

/// Per-light push constants used by both the point-light vertex and
/// fragment shaders. Layout mirrors the GLSL `Push` block (std430):
/// `{ vec4 position; vec4 color; float radius; }`.
pub const PointLightPushConstants = extern struct {
    position: math.Vec4 = @splat(0),
    color: math.Vec4 = @splat(0),
    radius: f32 = 0,
};

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
    const pushConstantRange: c.VkPushConstantRange = .{
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .offset = 0,
        .size = @sizeOf(PointLightPushConstants),
    };

    const descriptorSetLayouts = [_]c.VkDescriptorSetLayout{globalSetLayout};

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
    // Enable standard "source over" alpha blending so the soft-edged
    // billboards composite nicely over the scene (and over each other,
    // provided we render them back-to-front; see `render`). Mirrors
    // the upstream tutorial 27.
    Pipeline.enableAlphaBlending(&pipelineConfig);
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

/// Per-frame light update. Rotates every point-light game object
/// around the world's Y axis by `0.5 * frameTime` radians (matching
/// the upstream tutorial's demo animation) and copies the resulting
/// position + color + intensity into `ubo.pointLights`, capping the
/// count at `MAX_LIGHTS`.
pub fn update(self: *Self, frameInfo: *FrameInfo, ubo: *FrameInfo.GlobalUbo) void {
    _ = self;

    // Rotation around axis (0, -1, 0) by `angle`. Rodrigues' rotation formula
    // gives:
    //   x' = cos(a)*x - sin(a)*z
    //   y' = y
    //   z' = sin(a)*x + cos(a)*z
    const angle = 0.5 * frameInfo.frameTime;
    const cosA = std.math.cos(angle);
    const sinA = std.math.sin(angle);

    var lightIndex: usize = 0;
    var it = frameInfo.gameObjects.valueIterator();
    while (it.next()) |obj| {
        if (obj.pointLight == null) continue;

        std.debug.assert(lightIndex < FrameInfo.MAX_LIGHTS);

        const t = obj.transform.translation;
        obj.transform.translation = .{
            cosA * t[0] - sinA * t[2],
            t[1],
            sinA * t[0] + cosA * t[2],
        };

        ubo.pointLights[lightIndex] = .{
            .position = .{
                obj.transform.translation[0],
                obj.transform.translation[1],
                obj.transform.translation[2],
                1.0,
            },
            .color = .{
                obj.color[0],
                obj.color[1],
                obj.color[2],
                obj.pointLight.?.lightIntensity,
            },
        };

        lightIndex += 1;
    }
    ubo.numLights = @intCast(lightIndex);
}

/// Sort entry used by `render` to draw point-light billboards
/// back-to-front (farthest first). Mirrors the upstream
/// `std::map<float, id_t>` + reverse iteration in tutorial 27,
/// using a small stack-allocated array since we never have more
/// than `FrameInfo.MAX_LIGHTS` lights.
const SortedLight = struct {
    disSquared: f32,
    id: u64,

    fn farthestFirst(_: void, a: SortedLight, b: SortedLight) bool {
        return a.disSquared > b.disSquared;
    }
};

pub fn render(self: *Self, frameInfo: *FrameInfo) void {
    // Collect every point-light game object together with its
    // squared distance to the camera, then sort farthest-first so
    // the alpha-blended billboards composite correctly.
    var sorted: [FrameInfo.MAX_LIGHTS]SortedLight = undefined;
    var sortedCount: usize = 0;

    const cameraPos = frameInfo.camera.getPosition();
    var it = frameInfo.gameObjects.valueIterator();
    while (it.next()) |obj| {
        if (obj.pointLight == null) continue;
        std.debug.assert(sortedCount < FrameInfo.MAX_LIGHTS);

        const offset = cameraPos - obj.transform.translation;
        sorted[sortedCount] = .{
            .disSquared = math.dot3(offset, offset),
            .id = obj.id_t,
        };
        sortedCount += 1;
    }

    const slice = sorted[0..sortedCount];
    std.sort.insertion(SortedLight, slice, {}, SortedLight.farthestFirst);

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

    for (slice) |entry| {
        const obj = frameInfo.gameObjects.getPtr(entry.id) orelse continue;

        const push: PointLightPushConstants = .{
            .position = .{
                obj.transform.translation[0],
                obj.transform.translation[1],
                obj.transform.translation[2],
                1.0,
            },
            .color = .{
                obj.color[0],
                obj.color[1],
                obj.color[2],
                obj.pointLight.?.lightIntensity,
            },
            .radius = obj.transform.scale[0],
        };

        c.vkCmdPushConstants(
            frameInfo.commandBuffer,
            self.pipelineLayout,
            c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            0,
            @sizeOf(PointLightPushConstants),
            &push,
        );

        // Six vertices, one instance — the vertex shader picks the
        // quad corners from `OFFSETS[gl_VertexIndex]`.
        c.vkCmdDraw(frameInfo.commandBuffer, 6, 1, 0, 0);
    }
}

test "PointLightSystem has expected fields and types" {
    const fields = @typeInfo(Self).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 4), fields.len);
    try std.testing.expectEqual(std.mem.Allocator, @FieldType(Self, "alloc"));
    try std.testing.expectEqual(*Device, @FieldType(Self, "device"));
    try std.testing.expectEqual(?*Pipeline, @FieldType(Self, "pipeline"));
    try std.testing.expectEqual(c.VkPipelineLayout, @FieldType(Self, "pipelineLayout"));
}

test "PointLightPushConstants matches the GLSL push-constant layout" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(PointLightPushConstants, "position"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(PointLightPushConstants, "color"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(PointLightPushConstants, "radius"));
    try std.testing.expect(@sizeOf(PointLightPushConstants) <= 128);
}
