//! Minimal immediate-mode UI render system.
//!
//! Draws axis-aligned colored rectangles in screen space. The API is
//! intentionally immediate-mode: each frame the caller resets the
//! accumulated element list with `beginFrame`, pushes rectangles or a
//! small nested flex tree, and finally records the draws with
//! `render`. No retained widget state is kept between frames.
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

/// Upper bound on the number of UI elements drawable in a single
/// frame. Sized generously for a debug/immediate-mode UI; pushing past
/// this is a programming error.
pub const max_elements = 256;
pub const max_rects = max_elements;

/// Maximum nesting depth for `beginContainer` / `endContainer` pairs.
pub const max_layout_depth = 32;

/// Main-axis direction for a container's children.
pub const FlexDirection = enum { row, column };

/// Container styling. `direction` controls child layout, `padding` is
/// applied on all sides, `gap` separates adjacent children, and
/// `background` optionally draws the container's own rectangle before
/// its descendants. `hover_background`, when set, replaces the
/// background color while the mouse is inside the resolved container
/// bounds.
pub const ContainerStyle = struct {
    direction: FlexDirection = .row,
    padding: f32 = 0,
    gap: f32 = 0,
    background: ?math.Vec4 = null,
    hover_background: ?math.Vec4 = null,
};

/// Layout request for a child inside the current container. Along the
/// parent container's main axis, a fixed `width` / `height` wins; any
/// remaining space is distributed proportionally by `flex_grow`. Along
/// the cross axis, omitting the size fills the container's inner size.
pub const Layout = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    flex_grow: f32 = 0,
};

/// Per-rect push constants. Layout mirrors the GLSL `Push` block in
/// `ui.vert` (std430): `{ vec4 bounds; vec4 color; }`.
///
/// `bounds.xy` is the rect offset and `bounds.zw` its extent, both in
/// NDC ([-1, 1], +Y down). The offset/extent pair is packed into one
/// 16-byte-aligned storage field so `color` begins at offset 16, matching
/// the shader's std430 layout.
pub const UiPushConstants = extern struct {
    bounds: math.Vec4Storage align(16) = @splat(0),
    color: math.Vec4Storage align(16) = @splat(0),
};

const ElementKind = enum { rect, container };

/// Bounds in pixel coordinates (origin = top-left).
pub const Bounds = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

const Size = struct {
    main: f32,
    cross: f32,
};

const Cursor = struct {
    x: f32,
    y: f32,
};

/// A queued element. `x` / `y` / `w` / `h` are pixel coordinates.
/// Root elements are supplied directly by the caller; children are
/// resolved by `layoutElements` before rendering.
const Element = struct {
    kind: ElementKind,
    parent: ?usize,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    layout: Layout = .{},
    style: ContainerStyle = .{},
    color: math.Vec4 = @splat(0),
    hover_color: ?math.Vec4 = null,
    hovered: bool = false,
    draws: bool = false,
};

fn mainSize(layout: Layout, direction: FlexDirection) ?f32 {
    return switch (direction) {
        .row => layout.width,
        .column => layout.height,
    };
}

fn crossSize(layout: Layout, direction: FlexDirection) ?f32 {
    return switch (direction) {
        .row => layout.height,
        .column => layout.width,
    };
}

fn clampNonNegative(value: f32) f32 {
    return if (value > 0) value else 0;
}

fn childBounds(parent: Element, cursor: Cursor, size: Size) Bounds {
    return switch (parent.style.direction) {
        .row => .{ .x = cursor.x, .y = cursor.y, .w = size.main, .h = size.cross },
        .column => .{ .x = cursor.x, .y = cursor.y, .w = size.cross, .h = size.main },
    };
}

fn advanceCursor(cursor: *Cursor, direction: FlexDirection, main: f32, gap: f32) void {
    switch (direction) {
        .row => cursor.x += main + gap,
        .column => cursor.y += main + gap,
    }
}

fn isDirectChild(child: Element, parent_idx: usize) bool {
    return child.parent != null and child.parent.? == parent_idx;
}

/// Pure helper for callers that want hover logic for manually-known
/// bounds without duplicating the half-open edge convention.
pub fn pointInside(x: f32, y: f32, bounds: Bounds) bool {
    return x >= bounds.x and x < bounds.x + bounds.w and
        y >= bounds.y and y < bounds.y + bounds.h;
}

alloc: std.mem.Allocator,
device: *Device,
pipeline: ?*Pipeline,
pipelineLayout: c.VkPipelineLayout,
elements: [max_elements]Element = undefined,
elementCount: usize = 0,
layoutStack: [max_layout_depth]usize = undefined,
layoutDepth: usize = 0,
rectCount: usize = 0,
mouse_position: ?Cursor = null,

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

/// Reset the accumulated element list. Call once per frame before any
/// `rect` / flex-tree calls.
pub fn beginFrame(self: *Self) void {
    self.elementCount = 0;
    self.layoutDepth = 0;
    self.rectCount = 0;
    self.mouse_position = null;
}

/// Set the current mouse position in the same framebuffer-pixel space
/// as UI bounds. When set before `render`, every queued element's
/// hover state is resolved after flex layout, so nested elements can
/// react to their final computed bounds.
pub fn setMousePosition(self: *Self, x: f32, y: f32) void {
    self.mouse_position = .{ .x = x, .y = y };
}

/// Queue a filled rectangle for this frame. `x` / `y` are the
/// top-left corner and `w` / `h` the size, all in pixels (origin =
/// top-left of the window). `color` is RGBA in [0, 1]. This preserves
/// the original absolute-positioned API.
pub fn rect(self: *Self, x: f32, y: f32, w: f32, h: f32, color: math.Vec4) void {
    self.rectWithHover(x, y, w, h, color, null);
}

/// Queue a filled rectangle with an optional hover color. The hover
/// color is applied during `render` when the current mouse position is
/// inside the rectangle bounds.
pub fn rectWithHover(self: *Self, x: f32, y: f32, w: f32, h: f32, color: math.Vec4, hover_color: ?math.Vec4) void {
    _ = self.addElement(.{
        .kind = .rect,
        .parent = null,
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .color = color,
        .hover_color = hover_color,
        .draws = true,
    });
}

/// Begin a root container with explicit pixel bounds. Children pushed
/// until the matching `endContainer` are laid out according to
/// `style.direction`, `style.padding`, `style.gap`, and each child's
/// `Layout`.
pub fn beginContainer(self: *Self, x: f32, y: f32, w: f32, h: f32, style: ContainerStyle) void {
    const idx = self.addElement(.{
        .kind = .container,
        .parent = null,
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .style = style,
        .color = style.background orelse @as(math.Vec4, @splat(0)),
        .hover_color = style.hover_background,
        .draws = style.background != null or style.hover_background != null,
    });
    self.pushContainer(idx);
}

/// Begin a nested container as a child of the current container. Its
/// final bounds are resolved from `layout` during the flex pass.
pub fn beginChildContainer(self: *Self, layout: Layout, style: ContainerStyle) void {
    std.debug.assert(self.layoutDepth > 0);
    const idx = self.addElement(.{
        .kind = .container,
        .parent = self.layoutStack[self.layoutDepth - 1],
        .x = 0,
        .y = 0,
        .w = layout.width orelse 0,
        .h = layout.height orelse 0,
        .layout = layout,
        .style = style,
        .color = style.background orelse @as(math.Vec4, @splat(0)),
        .hover_color = style.hover_background,
        .draws = style.background != null or style.hover_background != null,
    });
    self.pushContainer(idx);
}

/// End the current container. Every begin call must have a matching
/// end call before `render`.
pub fn endContainer(self: *Self) void {
    std.debug.assert(self.layoutDepth > 0);
    self.layoutDepth -= 1;
}

/// Queue a rectangle inside the current container. The rectangle's
/// pixel bounds are resolved from `layout` during the flex pass.
pub fn flexRect(self: *Self, layout: Layout, color: math.Vec4) void {
    self.flexRectWithHover(layout, color, null);
}

/// Queue a rectangle inside the current container with an optional
/// hover color. Its hover state is resolved from the final flex-layout
/// bounds, not from the placeholder bounds available when queued.
pub fn flexRectWithHover(self: *Self, layout: Layout, color: math.Vec4, hover_color: ?math.Vec4) void {
    std.debug.assert(self.layoutDepth > 0);
    _ = self.addElement(.{
        .kind = .rect,
        .parent = self.layoutStack[self.layoutDepth - 1],
        .x = 0,
        .y = 0,
        .w = layout.width orelse 0,
        .h = layout.height orelse 0,
        .layout = layout,
        .color = color,
        .hover_color = hover_color,
        .draws = true,
    });
}

fn addElement(self: *Self, element: Element) usize {
    std.debug.assert(self.elementCount < max_elements);
    const idx = self.elementCount;
    self.elements[idx] = element;
    self.elementCount += 1;
    if (element.draws) self.rectCount += 1;
    return idx;
}

fn pushContainer(self: *Self, idx: usize) void {
    std.debug.assert(self.layoutDepth < max_layout_depth);
    self.layoutStack[self.layoutDepth] = idx;
    self.layoutDepth += 1;
}

fn layoutElements(self: *Self) void {
    std.debug.assert(self.layoutDepth == 0);

    var idx: usize = 0;
    while (idx < self.elementCount) : (idx += 1) {
        if (self.elements[idx].kind == .container) {
            self.layoutChildren(idx);
        }
    }
}

fn layoutChildren(self: *Self, parent_idx: usize) void {
    const parent = self.elements[parent_idx];
    const direction = parent.style.direction;
    const padding = parent.style.padding;
    const gap = parent.style.gap;

    const inner_x = parent.x + padding;
    const inner_y = parent.y + padding;
    const inner_w = clampNonNegative(parent.w - padding * 2.0);
    const inner_h = clampNonNegative(parent.h - padding * 2.0);
    const inner_main = switch (direction) {
        .row => inner_w,
        .column => inner_h,
    };
    const inner_cross = switch (direction) {
        .row => inner_h,
        .column => inner_w,
    };

    var child_count: usize = 0;
    var fixed_main: f32 = 0;
    var total_flex: f32 = 0;

    for (self.elements[0..self.elementCount]) |child| {
        if (!isDirectChild(child, parent_idx)) continue;
        child_count += 1;
        if (mainSize(child.layout, direction)) |size| {
            fixed_main += size;
        } else {
            total_flex += clampNonNegative(child.layout.flex_grow);
        }
    }

    if (child_count == 0) return;

    const total_gap = gap * @as(f32, @floatFromInt(child_count - 1));
    const remaining = clampNonNegative(inner_main - fixed_main - total_gap);
    var cursor: Cursor = .{ .x = inner_x, .y = inner_y };

    for (self.elements[0..self.elementCount]) |*child| {
        if (!isDirectChild(child.*, parent_idx)) continue;

        const flex = clampNonNegative(child.layout.flex_grow);
        const main = mainSize(child.layout, direction) orelse
            if (total_flex > 0) remaining * (flex / total_flex) else 0;
        const cross = crossSize(child.layout, direction) orelse inner_cross;
        const bounds = childBounds(parent, cursor, .{
            .main = clampNonNegative(main),
            .cross = clampNonNegative(cross),
        });

        child.x = bounds.x;
        child.y = bounds.y;
        child.w = bounds.w;
        child.h = bounds.h;

        advanceCursor(&cursor, direction, switch (direction) {
            .row => bounds.w,
            .column => bounds.h,
        }, gap);
    }
}

fn updateHoverState(self: *Self) void {
    for (self.elements[0..self.elementCount]) |*element| {
        element.hovered = if (self.mouse_position) |mouse|
            pointInside(mouse.x, mouse.y, .{
                .x = element.x,
                .y = element.y,
                .w = element.w,
                .h = element.h,
            })
        else
            false;
    }
}

fn elementColor(element: Element) math.Vec4 {
    if (element.hovered) {
        if (element.hover_color) |hover_color| return hover_color;
    }
    return element.color;
}

/// Record draw commands for every queued rectangle into
/// `commandBuffer`. Must be called inside an active render pass that
/// targets the swapchain image. `extent` is the current swapchain
/// extent, used to convert the pixel-space rects into NDC.
pub fn render(self: *Self, commandBuffer: c.VkCommandBuffer, extent: c.VkExtent2D) void {
    if (self.rectCount == 0) return;

    self.layoutElements();
    self.updateHoverState();

    self.pipeline.?.bind(commandBuffer);

    const fw: f32 = @floatFromInt(extent.width);
    const fh: f32 = @floatFromInt(extent.height);

    for (self.elements[0..self.elementCount]) |r| {
        if (!r.draws) continue;

        // Pixel space (origin top-left, +Y down) -> Vulkan NDC
        // ([-1, 1], +Y down). A pixel x maps to x/W*2 - 1.
        const push: UiPushConstants = .{
            .bounds = .{
                r.x / fw * 2.0 - 1.0,
                r.y / fh * 2.0 - 1.0,
                r.w / fw * 2.0,
                r.h / fh * 2.0,
            },
            .color = elementColor(r),
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
    sys.rect(0, 0, 10, 10, .{ 1, 0, 0, 1 });
    sys.rect(20, 0, 10, 10, .{ 0, 1, 0, 1 });
    try std.testing.expectEqual(@as(usize, 2), sys.rectCount);
    sys.beginFrame();
    try std.testing.expectEqual(@as(usize, 0), sys.rectCount);
    try std.testing.expectEqual(@as(usize, 0), sys.elementCount);
}

test "column container lays out fixed and flex children" {
    var sys: Self = .{
        .alloc = std.testing.allocator,
        // SAFETY: device/pipeline are not touched by the code under test.
        .device = undefined,
        .pipeline = null,
        .pipelineLayout = null,
    };

    sys.beginFrame();
    sys.beginContainer(10, 20, 200, 120, .{ .direction = .column, .padding = 10, .gap = 5 });
    sys.flexRect(.{ .height = 20 }, .{ 1, 0, 0, 1 });
    sys.flexRect(.{ .flex_grow = 1 }, .{ 0, 1, 0, 1 });
    sys.endContainer();

    sys.layoutElements();

    try std.testing.expectEqual(@as(f32, 20), sys.elements[1].x);
    try std.testing.expectEqual(@as(f32, 30), sys.elements[1].y);
    try std.testing.expectEqual(@as(f32, 180), sys.elements[1].w);
    try std.testing.expectEqual(@as(f32, 20), sys.elements[1].h);

    try std.testing.expectEqual(@as(f32, 20), sys.elements[2].x);
    try std.testing.expectEqual(@as(f32, 55), sys.elements[2].y);
    try std.testing.expectEqual(@as(f32, 180), sys.elements[2].w);
    try std.testing.expectEqual(@as(f32, 75), sys.elements[2].h);
}

test "row container distributes remaining space by flex grow" {
    var sys: Self = .{
        .alloc = std.testing.allocator,
        // SAFETY: device/pipeline are not touched by the code under test.
        .device = undefined,
        .pipeline = null,
        .pipelineLayout = null,
    };

    sys.beginFrame();
    sys.beginContainer(0, 0, 100, 20, .{ .direction = .row, .gap = 10 });
    sys.flexRect(.{ .width = 20 }, .{ 1, 0, 0, 1 });
    sys.flexRect(.{ .flex_grow = 1 }, .{ 0, 1, 0, 1 });
    sys.flexRect(.{ .flex_grow = 2 }, .{ 0, 0, 1, 1 });
    sys.endContainer();

    sys.layoutElements();

    try std.testing.expectEqual(@as(f32, 0), sys.elements[1].x);
    try std.testing.expectEqual(@as(f32, 20), sys.elements[1].w);
    try std.testing.expectApproxEqAbs(@as(f32, 30), sys.elements[2].x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), sys.elements[2].w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 60), sys.elements[3].x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40), sys.elements[3].w, 0.001);
}

test "nested containers resolve parent bounds before laying out descendants" {
    var sys: Self = .{
        .alloc = std.testing.allocator,
        // SAFETY: device/pipeline are not touched by the code under test.
        .device = undefined,
        .pipeline = null,
        .pipelineLayout = null,
    };

    sys.beginFrame();
    sys.beginContainer(10, 20, 300, 200, .{ .direction = .column, .padding = 10, .gap = 5 });
    sys.flexRect(.{ .height = 30 }, .{ 1, 0, 0, 1 });
    sys.beginChildContainer(.{ .flex_grow = 1 }, .{ .direction = .row, .padding = 8, .gap = 4 });
    sys.flexRect(.{ .width = 80 }, .{ 0, 1, 0, 1 });
    sys.flexRect(.{ .flex_grow = 1 }, .{ 0, 0, 1, 1 });
    sys.endContainer();
    sys.endContainer();

    sys.layoutElements();

    // Root container index 0: inner area is (20, 30, 280, 180).
    try std.testing.expectEqual(@as(f32, 20), sys.elements[1].x);
    try std.testing.expectEqual(@as(f32, 30), sys.elements[1].y);
    try std.testing.expectEqual(@as(f32, 280), sys.elements[1].w);
    try std.testing.expectEqual(@as(f32, 30), sys.elements[1].h);

    // Nested row container index 2 consumes the remaining column space.
    try std.testing.expectEqual(@as(f32, 20), sys.elements[2].x);
    try std.testing.expectEqual(@as(f32, 65), sys.elements[2].y);
    try std.testing.expectEqual(@as(f32, 280), sys.elements[2].w);
    try std.testing.expectEqual(@as(f32, 145), sys.elements[2].h);

    // Nested children are then laid out inside index 2's padded content box.
    try std.testing.expectEqual(@as(f32, 28), sys.elements[3].x);
    try std.testing.expectEqual(@as(f32, 73), sys.elements[3].y);
    try std.testing.expectEqual(@as(f32, 80), sys.elements[3].w);
    try std.testing.expectEqual(@as(f32, 129), sys.elements[3].h);

    try std.testing.expectEqual(@as(f32, 112), sys.elements[4].x);
    try std.testing.expectEqual(@as(f32, 73), sys.elements[4].y);
    try std.testing.expectEqual(@as(f32, 180), sys.elements[4].w);
    try std.testing.expectEqual(@as(f32, 129), sys.elements[4].h);
}

test "container backgrounds queue drawable elements before child rects" {
    var sys: Self = .{
        .alloc = std.testing.allocator,
        // SAFETY: device/pipeline are not touched by the code under test.
        .device = undefined,
        .pipeline = null,
        .pipelineLayout = null,
    };

    const root_bg: math.Vec4 = .{ 0.1, 0.2, 0.3, 0.4 };
    const child_bg: math.Vec4 = .{ 0.2, 0.3, 0.4, 0.5 };
    const rect_color: math.Vec4 = .{ 0.8, 0.7, 0.6, 1.0 };

    sys.beginFrame();
    sys.beginContainer(0, 0, 100, 40, .{ .direction = .row, .background = root_bg });
    sys.beginChildContainer(.{ .width = 50 }, .{ .direction = .column, .background = child_bg });
    sys.flexRect(.{ .flex_grow = 1 }, rect_color);
    sys.endContainer();
    sys.endContainer();

    try std.testing.expectEqual(@as(usize, 3), sys.rectCount);
    try std.testing.expect(sys.elements[0].draws);
    try std.testing.expect(sys.elements[1].draws);
    try std.testing.expect(sys.elements[2].draws);
    try std.testing.expectEqual(root_bg, sys.elements[0].color);
    try std.testing.expectEqual(child_bg, sys.elements[1].color);
    try std.testing.expectEqual(rect_color, sys.elements[2].color);
}

test "children without fixed main size or flex grow take zero main space" {
    var sys: Self = .{
        .alloc = std.testing.allocator,
        // SAFETY: device/pipeline are not touched by the code under test.
        .device = undefined,
        .pipeline = null,
        .pipelineLayout = null,
    };

    sys.beginFrame();
    sys.beginContainer(0, 0, 100, 50, .{ .direction = .row, .gap = 5 });
    sys.flexRect(.{}, .{ 1, 0, 0, 1 });
    sys.flexRect(.{ .width = 20 }, .{ 0, 1, 0, 1 });
    sys.endContainer();

    sys.layoutElements();

    try std.testing.expectEqual(@as(f32, 0), sys.elements[1].x);
    try std.testing.expectEqual(@as(f32, 0), sys.elements[1].w);
    try std.testing.expectEqual(@as(f32, 50), sys.elements[1].h);
    try std.testing.expectEqual(@as(f32, 5), sys.elements[2].x);
    try std.testing.expectEqual(@as(f32, 20), sys.elements[2].w);
}

test "padding larger than container clamps inner child sizes to zero" {
    var sys: Self = .{
        .alloc = std.testing.allocator,
        // SAFETY: device/pipeline are not touched by the code under test.
        .device = undefined,
        .pipeline = null,
        .pipelineLayout = null,
    };

    sys.beginFrame();
    sys.beginContainer(10, 15, 20, 10, .{ .direction = .column, .padding = 12 });
    sys.flexRect(.{ .flex_grow = 1 }, .{ 1, 0, 0, 1 });
    sys.endContainer();

    sys.layoutElements();

    try std.testing.expectEqual(@as(f32, 22), sys.elements[1].x);
    try std.testing.expectEqual(@as(f32, 27), sys.elements[1].y);
    try std.testing.expectEqual(@as(f32, 0), sys.elements[1].w);
    try std.testing.expectEqual(@as(f32, 0), sys.elements[1].h);
}

test "pointInside uses half-open rectangle bounds" {
    const bounds: Bounds = .{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try std.testing.expect(pointInside(10, 20, bounds));
    try std.testing.expect(pointInside(39.99, 59.99, bounds));
    try std.testing.expect(!pointInside(40, 20, bounds));
    try std.testing.expect(!pointInside(10, 60, bounds));
}

test "hover state is resolved after nested flex layout" {
    var sys: Self = .{
        .alloc = std.testing.allocator,
        // SAFETY: device/pipeline are not touched by the code under test.
        .device = undefined,
        .pipeline = null,
        .pipelineLayout = null,
    };

    sys.beginFrame();
    sys.setMousePosition(115, 75);
    sys.beginContainer(0, 0, 200, 100, .{
        .direction = .row,
        .padding = 10,
        .background = .{ 0.1, 0.1, 0.1, 1.0 },
        .hover_background = .{ 0.2, 0.2, 0.2, 1.0 },
    });
    sys.flexRectWithHover(.{ .width = 80 }, .{ 1, 0, 0, 1 }, .{ 0, 1, 0, 1 });
    sys.beginChildContainer(.{ .flex_grow = 1 }, .{
        .direction = .column,
        .background = .{ 0.0, 0.0, 0.1, 1.0 },
        .hover_background = .{ 0.0, 0.0, 0.3, 1.0 },
    });
    sys.flexRectWithHover(.{ .flex_grow = 1 }, .{ 0, 0, 1, 1 }, .{ 1, 1, 0, 1 });
    sys.endContainer();
    sys.endContainer();

    sys.layoutElements();
    sys.updateHoverState();

    try std.testing.expect(sys.elements[0].hovered);
    try std.testing.expect(!sys.elements[1].hovered);
    try std.testing.expect(sys.elements[2].hovered);
    try std.testing.expect(sys.elements[3].hovered);
    try std.testing.expectEqual(@as(math.Vec4, .{ 0.2, 0.2, 0.2, 1.0 }), elementColor(sys.elements[0]));
    try std.testing.expectEqual(@as(math.Vec4, .{ 1, 0, 0, 1 }), elementColor(sys.elements[1]));
    try std.testing.expectEqual(@as(math.Vec4, .{ 0.0, 0.0, 0.3, 1.0 }), elementColor(sys.elements[2]));
    try std.testing.expectEqual(@as(math.Vec4, .{ 1, 1, 0, 1 }), elementColor(sys.elements[3]));
}

test "beginFrame clears mouse hover state for the next frame" {
    var sys: Self = .{
        .alloc = std.testing.allocator,
        // SAFETY: device/pipeline are not touched by the code under test.
        .device = undefined,
        .pipeline = null,
        .pipelineLayout = null,
    };

    sys.beginFrame();
    sys.setMousePosition(5, 5);
    sys.rectWithHover(0, 0, 10, 10, .{ 1, 0, 0, 1 }, .{ 0, 1, 0, 1 });
    sys.layoutElements();
    sys.updateHoverState();
    try std.testing.expect(sys.elements[0].hovered);

    sys.beginFrame();
    sys.rectWithHover(0, 0, 10, 10, .{ 1, 0, 0, 1 }, .{ 0, 1, 0, 1 });
    sys.layoutElements();
    sys.updateHoverState();
    try std.testing.expect(!sys.elements[0].hovered);
    try std.testing.expectEqual(@as(math.Vec4, .{ 1, 0, 0, 1 }), elementColor(sys.elements[0]));
}
