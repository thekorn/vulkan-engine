const std = @import("std");

const c = @import("c.zig").c;
const cglm = @import("c.zig").cglm;
const GameObject = @import("GameObject.zig");

const Self = @This();

pub const KeyMappings = struct {
    moveLeft: c_int = c.GLFW_KEY_A,
    moveRight: c_int = c.GLFW_KEY_D,
    moveForward: c_int = c.GLFW_KEY_W,
    moveBackward: c_int = c.GLFW_KEY_S,
    moveUp: c_int = c.GLFW_KEY_E,
    moveDown: c_int = c.GLFW_KEY_Q,
    lookLeft: c_int = c.GLFW_KEY_LEFT,
    lookRight: c_int = c.GLFW_KEY_RIGHT,
    lookUp: c_int = c.GLFW_KEY_UP,
    lookDown: c_int = c.GLFW_KEY_DOWN,
};

keys: KeyMappings = .{},
moveSpeed: f32 = 3.0,
lookSpeed: f32 = 1.5,

inline fn vec3Dot(a: cglm.vec3, b: cglm.vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

inline fn vec3Normalize(v: cglm.vec3) cglm.vec3 {
    const len = @sqrt(vec3Dot(v, v));
    std.debug.assert(len > 0.0);
    const inv = 1.0 / len;
    return .{ v[0] * inv, v[1] * inv, v[2] * inv };
}

/// Update the given game object's transform based on the currently
/// pressed keys, integrated over `dt` seconds. Yaw (Y rotation) is
/// wrapped to `[0, 2*pi)` and pitch (X rotation) is clamped to roughly
/// +/- 85 degrees, matching the C++ tutorial.
pub fn moveInPlaneXZ(
    self: *const Self,
    window: *c.GLFWwindow,
    dt: f32,
    gameObject: *GameObject,
) void {
    var rotate: cglm.vec3 = .{ 0, 0, 0 };
    if (c.glfwGetKey(window, self.keys.lookRight) == c.GLFW_PRESS) rotate[1] += 1.0;
    if (c.glfwGetKey(window, self.keys.lookLeft) == c.GLFW_PRESS) rotate[1] -= 1.0;
    if (c.glfwGetKey(window, self.keys.lookUp) == c.GLFW_PRESS) rotate[0] += 1.0;
    if (c.glfwGetKey(window, self.keys.lookDown) == c.GLFW_PRESS) rotate[0] -= 1.0;

    if (vec3Dot(rotate, rotate) > std.math.floatEps(f32)) {
        const r = vec3Normalize(rotate);
        const k = self.lookSpeed * dt;
        gameObject.transform.rotation[0] += k * r[0];
        gameObject.transform.rotation[1] += k * r[1];
        gameObject.transform.rotation[2] += k * r[2];
    }

    // Limit pitch (X rotation) to roughly +/- 85 degrees and wrap yaw
    // (Y rotation) into [0, 2*pi).
    const two_pi: f32 = 2.0 * std.math.pi;
    gameObject.transform.rotation[0] = std.math.clamp(
        gameObject.transform.rotation[0],
        -1.5,
        1.5,
    );
    gameObject.transform.rotation[1] = @mod(gameObject.transform.rotation[1], two_pi);

    const yaw = gameObject.transform.rotation[1];
    const forwardDir: cglm.vec3 = .{ @sin(yaw), 0.0, @cos(yaw) };
    const rightDir: cglm.vec3 = .{ forwardDir[2], 0.0, -forwardDir[0] };
    const upDir: cglm.vec3 = .{ 0.0, -1.0, 0.0 };

    var moveDir: cglm.vec3 = .{ 0, 0, 0 };
    if (c.glfwGetKey(window, self.keys.moveForward) == c.GLFW_PRESS) {
        moveDir[0] += forwardDir[0];
        moveDir[1] += forwardDir[1];
        moveDir[2] += forwardDir[2];
    }
    if (c.glfwGetKey(window, self.keys.moveBackward) == c.GLFW_PRESS) {
        moveDir[0] -= forwardDir[0];
        moveDir[1] -= forwardDir[1];
        moveDir[2] -= forwardDir[2];
    }
    if (c.glfwGetKey(window, self.keys.moveRight) == c.GLFW_PRESS) {
        moveDir[0] += rightDir[0];
        moveDir[1] += rightDir[1];
        moveDir[2] += rightDir[2];
    }
    if (c.glfwGetKey(window, self.keys.moveLeft) == c.GLFW_PRESS) {
        moveDir[0] -= rightDir[0];
        moveDir[1] -= rightDir[1];
        moveDir[2] -= rightDir[2];
    }
    if (c.glfwGetKey(window, self.keys.moveUp) == c.GLFW_PRESS) {
        moveDir[0] += upDir[0];
        moveDir[1] += upDir[1];
        moveDir[2] += upDir[2];
    }
    if (c.glfwGetKey(window, self.keys.moveDown) == c.GLFW_PRESS) {
        moveDir[0] -= upDir[0];
        moveDir[1] -= upDir[1];
        moveDir[2] -= upDir[2];
    }

    if (vec3Dot(moveDir, moveDir) > std.math.floatEps(f32)) {
        const m = vec3Normalize(moveDir);
        const k = self.moveSpeed * dt;
        gameObject.transform.translation[0] += k * m[0];
        gameObject.transform.translation[1] += k * m[1];
        gameObject.transform.translation[2] += k * m[2];
    }
}

// ---------------------------------------------------------------------------
// Tests (pure logic only — no GLFW window required)
// ---------------------------------------------------------------------------

test "KeyboardMovementController defaults" {
    const ctrl: Self = .{};
    try std.testing.expectEqual(@as(f32, 3.0), ctrl.moveSpeed);
    try std.testing.expectEqual(@as(f32, 1.5), ctrl.lookSpeed);
    try std.testing.expectEqual(@as(c_int, c.GLFW_KEY_W), ctrl.keys.moveForward);
    try std.testing.expectEqual(@as(c_int, c.GLFW_KEY_S), ctrl.keys.moveBackward);
    try std.testing.expectEqual(@as(c_int, c.GLFW_KEY_A), ctrl.keys.moveLeft);
    try std.testing.expectEqual(@as(c_int, c.GLFW_KEY_D), ctrl.keys.moveRight);
    try std.testing.expectEqual(@as(c_int, c.GLFW_KEY_E), ctrl.keys.moveUp);
    try std.testing.expectEqual(@as(c_int, c.GLFW_KEY_Q), ctrl.keys.moveDown);
    try std.testing.expectEqual(@as(c_int, c.GLFW_KEY_LEFT), ctrl.keys.lookLeft);
    try std.testing.expectEqual(@as(c_int, c.GLFW_KEY_RIGHT), ctrl.keys.lookRight);
    try std.testing.expectEqual(@as(c_int, c.GLFW_KEY_UP), ctrl.keys.lookUp);
    try std.testing.expectEqual(@as(c_int, c.GLFW_KEY_DOWN), ctrl.keys.lookDown);
}

test "vec3Normalize returns unit vector" {
    const v: cglm.vec3 = .{ 3.0, 0.0, 4.0 };
    const n = vec3Normalize(v);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), n[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), n[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), n[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), vec3Dot(n, n), 1e-6);
}

test "vec3Dot computes the dot product" {
    const a: cglm.vec3 = .{ 1.0, 2.0, 3.0 };
    const b: cglm.vec3 = .{ -1.0, 0.5, 2.0 };
    try std.testing.expectApproxEqAbs(@as(f32, -1.0 + 1.0 + 6.0), vec3Dot(a, b), 1e-6);
}
