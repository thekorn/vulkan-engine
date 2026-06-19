//! Minimal immediate-mode UI render system.
//!
//! Draws axis-aligned colored rectangles in screen space. The API is
//! intentionally immediate-mode: each frame the caller resets the
//! accumulated rect list with `beginFrame`, pushes rectangles with
//! `rect`, and finally records the draws with `render`. No retained
//! widget state is kept between frames.
//!
//! Like `PointLightSystem`, the pipeline binds no vertex buffers: the
//! vertex shader (`ui.vert`) emits a unit quad from `gl_VertexIndex`
//! and the per-rect position / size / color travel as push constants.
//! Rectangles are specified in pixel coordinates with the origin at
//! the top-left corner of the window; `render` converts them to
//! Vulkan NDC using the current swapchain extent.

const std = @import("std");

const c = @import("../c.zig").c;
const math = @import("../math.zig");
const Device = @import("../Device.zig");
const Pipeline = @import("../Pipeline.zig");
const checkSuccess = @import("../utils.zig").checkSuccess;

const Self = @This();

/// Upper bound on the number of rectangles drawable in a single frame.
/// Sized generously for a debug/immediate-mode UI; pushing past this
/// is a programming error (asserted in `rect`).
pub const max_rects = 256;

/// Per-rect push constants. Layout mirrors the GLSL `Push` block in
/// `ui.vert` (std430): `{ vec4 bounds; vec4 color; vec4 params; }`.
///
/// `bounds.xy` is the rect offset and `bounds.zw` its extent, both in
/// NDC ([-1, 1], +Y down). The offset/extent pair is packed into one
/// `math.Vec4` on purpose: a `@Vector(2, f32)` is 16-byte aligned
/// (and 16 bytes wide) on some targets (e.g. x86-64 Linux), so two
/// `Vec2` fields would land at offsets 0/16 with `color` at 32 and
/// break the std430 layout the shader expects. A single `Vec4` is
/// reliably 16 bytes on every platform, keeping `bounds = 0,
/// color = 16, params = 32`.
///
/// `params.xy` is the rect size in pixels and `params.z` the corner
/// radius in pixels; the fragment shader uses these to anti-alias the
/// rounded corners.
pub const UiPushConstants = extern struct {
    bounds: math.Vec4 = @splat(0),
    color: math.Vec4 = @splat(0),
    params: math.Vec4 = @splat(0),
};

/// A rectangle queued for drawing this frame, in pixel coordinates
/// (origin = top-left of the window). `radius` is the corner radius in
/// pixels (0 = sharp corners).
const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: math.Vec4,
    radius: f32,
};

alloc: std.mem.Allocator,
device: *Device,
pipeline: ?*Pipeline,
pipelineLayout: c.VkPipelineLayout,
rects: [max_rects]Rect = undefined,
rectCount: usize = 0,

pub fn init(
    alloc: std.mem.Allocator,
    device: *Device,
    renderPass: c.VkRenderPass,
) !Self {
    var self: Self = .{
        .alloc = alloc,
        .device = device,
        .pipeline = null,
        // SAFETY: written by createPipelineLayout immediately below before any read.
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
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT,
        .offset = 0,
        .size = @sizeOf(UiPushConstants),
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
    // Standard "source over" alpha blending so translucent rects
    // composite over the scene.
    Pipeline.enableAlphaBlending(&pipelineConfig);
    // The UI is a 2D overlay: don't test or write depth so rects
    // always draw on top regardless of what was rendered before.
    pipelineConfig.depthStencilInfo.depthTestEnable = c.VK_FALSE;
    pipelineConfig.depthStencilInfo.depthWriteEnable = c.VK_FALSE;
    // Vertices are generated procedurally from `gl_VertexIndex`; no
    // vertex buffers are bound.
    pipelineConfig.bindingDescriptions = &.{};
    pipelineConfig.attributeDescriptions = &.{};
    pipelineConfig.renderPass = renderPass;
    pipelineConfig.pipelineLayout = self.pipelineLayout;

    self.pipeline = try Pipeline.init(
        self.alloc,
        self.device,
        @embedFile("ui.frag.spv"),
        @embedFile("ui.vert.spv"),
        pipelineConfig,
    );
}

/// Reset the accumulated rect list. Call once per frame before any
/// `rect` calls.
pub fn beginFrame(self: *Self) void {
    self.rectCount = 0;
}

/// Queue a filled rectangle for this frame. `x` / `y` are the
/// top-left corner and `w` / `h` the size, all in pixels (origin =
/// top-left of the window). `color` is RGBA in [0, 1]. `radius` is the
/// corner radius in pixels (0 = sharp corners); it is clamped in the
/// shader to at most half the shortest side.
pub fn rect(self: *Self, x: f32, y: f32, w: f32, h: f32, color: math.Vec4, radius: f32) void {
    std.debug.assert(self.rectCount < max_rects);
    self.rects[self.rectCount] = .{ .x = x, .y = y, .w = w, .h = h, .color = color, .radius = radius };
    self.rectCount += 1;
}

/// Record draw commands for every queued rectangle into
/// `commandBuffer`. Must be called inside an active render pass that
/// targets the swapchain image. `extent` is the current swapchain
/// extent, used to convert the pixel-space rects into NDC.
pub fn render(self: *Self, commandBuffer: c.VkCommandBuffer, extent: c.VkExtent2D) void {
    if (self.rectCount == 0) return;

    self.pipeline.?.bind(commandBuffer);

    const fw: f32 = @floatFromInt(extent.width);
    const fh: f32 = @floatFromInt(extent.height);

    for (self.rects[0..self.rectCount]) |r| {
        // Pixel space (origin top-left, +Y down) -> Vulkan NDC
        // ([-1, 1], +Y down). A pixel x maps to x/W*2 - 1.
        const push: UiPushConstants = .{
            .bounds = .{
                r.x / fw * 2.0 - 1.0,
                r.y / fh * 2.0 - 1.0,
                r.w / fw * 2.0,
                r.h / fh * 2.0,
            },
            .color = r.color,
            // Rect size + corner radius in pixels for the rounded-box
            // SDF in the fragment shader.
            .params = .{ r.w, r.h, r.radius, 0 },
        };

        c.vkCmdPushConstants(
            commandBuffer,
            self.pipelineLayout,
            c.VK_SHADER_STAGE_VERTEX_BIT,
            0,
            @sizeOf(UiPushConstants),
            &push,
        );

        // Six vertices, one instance — the vertex shader picks the
        // quad corners from `OFFSETS[gl_VertexIndex]`.
        c.vkCmdDraw(commandBuffer, 6, 1, 0, 0);
    }
}

test "UiRenderSystem has expected fields and types" {
    try std.testing.expectEqual(std.mem.Allocator, @FieldType(Self, "alloc"));
    try std.testing.expectEqual(*Device, @FieldType(Self, "device"));
    try std.testing.expectEqual(?*Pipeline, @FieldType(Self, "pipeline"));
    try std.testing.expectEqual(c.VkPipelineLayout, @FieldType(Self, "pipelineLayout"));
}

test "UiPushConstants matches the GLSL push-constant layout" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(UiPushConstants, "bounds"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(UiPushConstants, "color"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(UiPushConstants, "params"));
    try std.testing.expect(@sizeOf(UiPushConstants) <= 128);
}

test "beginFrame resets the queued rect count" {
    var sys: Self = .{
        .alloc = std.testing.allocator,
        // SAFETY: device/pipeline are not touched by the code under test.
        .device = undefined,
        .pipeline = null,
        .pipelineLayout = null,
    };
    sys.rect(0, 0, 10, 10, .{ 1, 0, 0, 1 }, 0);
    sys.rect(20, 0, 10, 10, .{ 0, 1, 0, 1 }, 4);
    try std.testing.expectEqual(@as(usize, 2), sys.rectCount);
    sys.beginFrame();
    try std.testing.expectEqual(@as(usize, 0), sys.rectCount);
}
