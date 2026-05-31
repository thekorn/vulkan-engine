//! Per-frame context passed from `FirstApp`'s render loop into the
//! render systems (`SimpleRenderSystem`, `PointLightSystem`).
//!
//! Mirrors `FrameInfo` from the upstream Little Vulkan Engine tutorial.
//! Bundling these fields keeps render-system signatures stable as we
//! grow the per-frame state (e.g. when descriptor sets and global UBOs
//! come online).
//!
//! Also defines `GlobalUbo` and the `PointLight` slot type used both
//! by the global UBO and by `PointLightSystem.update` — mirroring the
//! upstream tutorial's move of `GlobalUbo` out of `first_app.cpp` and
//! into `lve_frame_info.hpp` so render systems can mutate it from
//! their `update()` calls.

const std = @import("std");

const c = @import("c.zig").c;
const math = @import("math.zig");
const Camera = @import("Camera.zig");
const GameObject = @import("GameObject.zig");

/// Maximum number of point lights the global UBO can hold; the
/// fragment shader iterates `[0, ubo.numLights)` so the actual count
/// per frame may be smaller. Must match the array size in the GLSL
/// `GlobalUbo` declaration.
pub const MAX_LIGHTS: usize = 10;

/// Single point-light slot inside the global UBO. Layout mirrors the
/// GLSL `PointLight { vec4 position; vec4 color; }` struct (std140);
/// `position.w` is ignored, `color.w` carries the per-light
/// intensity.
pub const PointLight = extern struct {
    position: math.Vec4 = @splat(0),
    color: math.Vec4 = @splat(0),
};

/// Per-frame uniform data uploaded to the global UBO. Mirrors
/// `GlobalUbo` in `lve_frame_info.hpp` (upstream tutorial 25, which
/// moved this struct out of `first_app.cpp` so render systems can
/// mutate it from their `update()` calls).
///
/// Stored as an `extern struct` so the field layout matches what GLSL
/// sees at `set = 0, binding = 0`.
pub const GlobalUbo = extern struct {
    /// Projection and view are stored separately so the point-light
    /// vertex shader can extract the camera basis from `view` to
    /// build a camera-facing billboard.
    projection: math.Mat4 = math.identity_mat4,
    view: math.Mat4 = math.identity_mat4,
    /// `xyz` = ambient color, `w` = intensity.
    ambientLightColor: math.Vec4 = .{ 1.0, 1.0, 1.0, 0.02 },
    /// Up to `MAX_LIGHTS` point lights. Only the first
    /// `numLights` entries are read by the fragment shader.
    /// `PointLightSystem.update` fills these in each frame from
    /// game objects that carry a `PointLightComponent`.
    pointLights: [MAX_LIGHTS]PointLight = @splat(.{}),
    numLights: i32 = 0,
};

const Self = @This();

frameIndex: usize,
frameTime: f32,
commandBuffer: c.VkCommandBuffer,
camera: *Camera,
/// Per-frame descriptor set bound at set = 0 by the render system.
/// Currently exposes the global UBO (projection-view matrix +
/// lights).
globalDescriptorSet: c.VkDescriptorSet,
/// Scene's renderable entities keyed by `GameObject.id_t`. Mirrors
/// the `LveGameObject::Map &gameObjects` field added in the upstream
/// tutorial so render systems can iterate the scene directly from
/// `FrameInfo` instead of taking a separate slice argument.
gameObjects: *GameObject.Map,

test "FrameInfo has expected fields and types" {
    const fields = @typeInfo(Self).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 6), fields.len);
    try std.testing.expectEqual(usize, @FieldType(Self, "frameIndex"));
    try std.testing.expectEqual(f32, @FieldType(Self, "frameTime"));
    try std.testing.expectEqual(c.VkCommandBuffer, @FieldType(Self, "commandBuffer"));
    try std.testing.expectEqual(*Camera, @FieldType(Self, "camera"));
    try std.testing.expectEqual(c.VkDescriptorSet, @FieldType(Self, "globalDescriptorSet"));
    try std.testing.expectEqual(*GameObject.Map, @FieldType(Self, "gameObjects"));
}

test "PointLight layout matches std140 (32 bytes, 16-byte aligned)" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(PointLight));
    try std.testing.expectEqual(@as(usize, 16), @alignOf(PointLight));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(PointLight, "position"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(PointLight, "color"));
}

test "GlobalUbo field offsets match std140 layout the shader expects" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(GlobalUbo, "projection"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(GlobalUbo, "view"));
    try std.testing.expectEqual(@as(usize, 128), @offsetOf(GlobalUbo, "ambientLightColor"));
    try std.testing.expectEqual(@as(usize, 144), @offsetOf(GlobalUbo, "pointLights"));
    // 144 + 10 * 32 = 464
    try std.testing.expectEqual(@as(usize, 464), @offsetOf(GlobalUbo, "numLights"));
}

test "GlobalUbo default has zero lights so the fragment loop is a no-op" {
    const ubo: GlobalUbo = .{};
    try std.testing.expectEqual(@as(i32, 0), ubo.numLights);
}
