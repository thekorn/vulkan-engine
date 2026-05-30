//! Per-frame context passed from `FirstApp`'s render loop into the
//! render systems (currently just `SimpleRenderSystem`).
//!
//! Mirrors `FrameInfo` from the upstream Little Vulkan Engine tutorial.
//! Bundling these fields keeps render-system signatures stable as we
//! grow the per-frame state (e.g. when descriptor sets and global UBOs
//! come online).

const std = @import("std");

const c = @import("c.zig").c;
const Camera = @import("Camera.zig");

const Self = @This();

frameIndex: usize,
frameTime: f32,
commandBuffer: c.VkCommandBuffer,
camera: *Camera,
/// Per-frame descriptor set bound at set = 0 by the render system.
/// Currently exposes the global UBO (projection-view matrix + light
/// direction); future tutorials may add more bindings.
globalDescriptorSet: c.VkDescriptorSet,

test "FrameInfo has expected fields and types" {
    const fields = @typeInfo(Self).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 5), fields.len);
    try std.testing.expectEqual(usize, @FieldType(Self, "frameIndex"));
    try std.testing.expectEqual(f32, @FieldType(Self, "frameTime"));
    try std.testing.expectEqual(c.VkCommandBuffer, @FieldType(Self, "commandBuffer"));
    try std.testing.expectEqual(*Camera, @FieldType(Self, "camera"));
    try std.testing.expectEqual(c.VkDescriptorSet, @FieldType(Self, "globalDescriptorSet"));
}
