const std = @import("std");

const c = @import("c.zig").c;
const math = @import("math.zig");
const Vec3 = math.Vec3;
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
    var rotate: Vec3 = .{ 0, 0, 0 };
    if (c.glfwGetKey(window, self.keys.lookRight) == c.GLFW_PRESS) rotate[1] += 1.0;
    if (c.glfwGetKey(window, self.keys.lookLeft) == c.GLFW_PRESS) rotate[1] -= 1.0;
    if (c.glfwGetKey(window, self.keys.lookUp) == c.GLFW_PRESS) rotate[0] += 1.0;
    if (c.glfwGetKey(window, self.keys.lookDown) == c.GLFW_PRESS) rotate[0] -= 1.0;

    if (math.dot3(rotate, rotate) > std.math.floatEps(f32)) {
        const r = math.normalize3(rotate);
        const k: Vec3 = @splat(self.lookSpeed * dt);
        gameObject.transform.rotation += k * r;
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
    const forwardDir: Vec3 = .{ @sin(yaw), 0.0, @cos(yaw) };
    const rightDir: Vec3 = .{ forwardDir[2], 0.0, -forwardDir[0] };
    const upDir: Vec3 = .{ 0.0, -1.0, 0.0 };

    var moveDir: Vec3 = .{ 0, 0, 0 };
    if (c.glfwGetKey(window, self.keys.moveForward) == c.GLFW_PRESS) moveDir += forwardDir;
    if (c.glfwGetKey(window, self.keys.moveBackward) == c.GLFW_PRESS) moveDir -= forwardDir;
    if (c.glfwGetKey(window, self.keys.moveRight) == c.GLFW_PRESS) moveDir += rightDir;
    if (c.glfwGetKey(window, self.keys.moveLeft) == c.GLFW_PRESS) moveDir -= rightDir;
    if (c.glfwGetKey(window, self.keys.moveUp) == c.GLFW_PRESS) moveDir += upDir;
    if (c.glfwGetKey(window, self.keys.moveDown) == c.GLFW_PRESS) moveDir -= upDir;

    if (math.dot3(moveDir, moveDir) > std.math.floatEps(f32)) {
        const m = math.normalize3(moveDir);
        const k: Vec3 = @splat(self.moveSpeed * dt);
        gameObject.transform.translation += k * m;
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
