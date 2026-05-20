const std = @import("std");
const c = @import("c.zig").c;
const cglm = @import("c.zig").cglm;

pub fn checkSuccess(result: c.VkResult) !void {
    switch (result) {
        c.VK_SUCCESS => {},
        else => return error.Unexpected,
    }
}

pub fn vec2s(v: cglm.vec2) cglm.vec2s {
    return .{ .raw = v };
}
pub fn vec3s(v: cglm.vec3) cglm.vec3s {
    return .{ .raw = v };
}

pub fn mat2s(v: cglm.mat2) cglm.mat2s {
    return .{ .raw = v };
}

test "checkSuccess returns void on VK_SUCCESS" {
    try checkSuccess(c.VK_SUCCESS);
}

test "checkSuccess returns Unexpected on VK_NOT_READY" {
    try std.testing.expectError(error.Unexpected, checkSuccess(c.VK_NOT_READY));
}

test "checkSuccess returns Unexpected on VK_TIMEOUT" {
    try std.testing.expectError(error.Unexpected, checkSuccess(c.VK_TIMEOUT));
}

test "checkSuccess returns Unexpected on VK_ERROR_OUT_OF_HOST_MEMORY" {
    try std.testing.expectError(error.Unexpected, checkSuccess(c.VK_ERROR_OUT_OF_HOST_MEMORY));
}

test "checkSuccess returns Unexpected on VK_ERROR_DEVICE_LOST" {
    try std.testing.expectError(error.Unexpected, checkSuccess(c.VK_ERROR_DEVICE_LOST));
}

test "checkSuccess returns Unexpected on VK_INCOMPLETE" {
    try std.testing.expectError(error.Unexpected, checkSuccess(c.VK_INCOMPLETE));
}
