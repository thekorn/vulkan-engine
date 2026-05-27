const std = @import("std");

const cglm = @import("c.zig").cglm;

const Self = @This();

// Column-major 4x4 projection matrix, identity by default.
projectionMatrix: cglm.mat4 = .{
    .{ 1.0, 0.0, 0.0, 0.0 },
    .{ 0.0, 1.0, 0.0, 0.0 },
    .{ 0.0, 0.0, 1.0, 0.0 },
    .{ 0.0, 0.0, 0.0, 1.0 },
},

pub fn setOrthographicProjection(
    self: *Self,
    left: f32,
    right: f32,
    top: f32,
    bottom: f32,
    near: f32,
    far: f32,
) void {
    // Reset to identity, then overwrite the elements that differ.
    self.projectionMatrix = .{
        .{ 1.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 1.0 },
    };
    self.projectionMatrix[0][0] = 2.0 / (right - left);
    self.projectionMatrix[1][1] = 2.0 / (bottom - top);
    self.projectionMatrix[2][2] = 1.0 / (far - near);
    self.projectionMatrix[3][0] = -(right + left) / (right - left);
    self.projectionMatrix[3][1] = -(bottom + top) / (bottom - top);
    self.projectionMatrix[3][2] = -near / (far - near);
}

pub fn setPerspectiveProjection(
    self: *Self,
    fovy: f32,
    aspect: f32,
    near: f32,
    far: f32,
) void {
    // Guard against a zero aspect ratio (which would cause a divide-by-zero
    // in `1 / (aspect * tanHalfFovy)`). The upstream C++ tutorial writes
    // `assert(glm::abs(aspect - epsilon) > 0.0f)`, which still passes when
    // `aspect == 0`; use a more meaningful comparison here.
    std.debug.assert(@abs(aspect) > std.math.floatEps(f32));
    const tanHalfFovy = std.math.tan(fovy / 2.0);
    self.projectionMatrix = .{
        .{ 0.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 0.0 },
    };
    self.projectionMatrix[0][0] = 1.0 / (aspect * tanHalfFovy);
    self.projectionMatrix[1][1] = 1.0 / (tanHalfFovy);
    self.projectionMatrix[2][2] = far / (far - near);
    self.projectionMatrix[2][3] = 1.0;
    self.projectionMatrix[3][2] = -(far * near) / (far - near);
}

pub fn getProjection(self: *const Self) cglm.mat4 {
    return self.projectionMatrix;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Camera default projection is the identity matrix" {
    const cam: Self = .{};
    const m = cam.getProjection();
    inline for (0..4) |col| {
        inline for (0..4) |row| {
            const expected: f32 = if (col == row) 1.0 else 0.0;
            try std.testing.expectApproxEqAbs(expected, m[col][row], 1e-6);
        }
    }
}

test "Camera.setOrthographicProjection maps the box to clip space" {
    var cam: Self = .{};
    cam.setOrthographicProjection(-1.0, 1.0, -1.0, 1.0, 0.0, 1.0);
    const m = cam.getProjection();
    // With left=-1, right=1, top=-1, bottom=1, near=0, far=1 this should
    // yield diag(1, 1, 1, 1) with zero translation: identity.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[1][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[2][2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[3][3], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[3][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[3][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[3][2], 1e-6);
}

test "Camera.setPerspectiveProjection fills the expected entries" {
    var cam: Self = .{};
    const fovy: f32 = std.math.pi / 2.0; // 90 degrees
    cam.setPerspectiveProjection(fovy, 1.0, 0.1, 10.0);
    const m = cam.getProjection();
    const tanHalf = std.math.tan(fovy / 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / tanHalf), m[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / tanHalf), m[1][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0 / (10.0 - 0.1)), m[2][2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[2][3], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -(10.0 * 0.1) / (10.0 - 0.1)), m[3][2], 1e-6);
    // entries not set should be zero
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[0][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[3][3], 1e-6);
}
