const std = @import("std");

const math = @import("math.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

const Self = @This();

// Column-major 4x4 projection matrix, identity by default.
projectionMatrix: Mat4 = math.identity_mat4,
// Column-major 4x4 view matrix, identity by default.
viewMatrix: Mat4 = math.identity_mat4,
// Column-major 4x4 inverse view matrix (camera-to-world transform),
// identity by default. Updated alongside `viewMatrix` by
// `setViewDirection` / `setViewYXZ`. The fragment shader reads
// `inverseView[3].xyz` to recover the camera position in world space
// for the specular lighting calculation.
inverseViewMatrix: Mat4 = math.identity_mat4,

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
    self.projectionMatrix = math.identity_mat4;
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

pub fn getProjection(self: *const Self) Mat4 {
    return self.projectionMatrix;
}

pub fn getView(self: *const Self) Mat4 {
    return self.viewMatrix;
}

pub fn getInverseView(self: *const Self) Mat4 {
    return self.inverseViewMatrix;
}

pub const default_up: Vec3 = .{ 0.0, -1.0, 0.0 };

pub fn setViewDirection(
    self: *Self,
    position: Vec3,
    direction: Vec3,
    up: Vec3,
) void {
    const w = math.normalize3(direction);
    const u = math.normalize3(math.cross3(w, up));
    const v = math.cross3(w, u);

    self.viewMatrix = math.identity_mat4;
    self.viewMatrix[0][0] = u[0];
    self.viewMatrix[1][0] = u[1];
    self.viewMatrix[2][0] = u[2];
    self.viewMatrix[0][1] = v[0];
    self.viewMatrix[1][1] = v[1];
    self.viewMatrix[2][1] = v[2];
    self.viewMatrix[0][2] = w[0];
    self.viewMatrix[1][2] = w[1];
    self.viewMatrix[2][2] = w[2];
    self.viewMatrix[3][0] = -math.dot3(u, position);
    self.viewMatrix[3][1] = -math.dot3(v, position);
    self.viewMatrix[3][2] = -math.dot3(w, position);

    // Inverse view = camera-to-world transform: the orthonormal basis
    // (u, v, w) written into the *rows* of the rotation block of
    // `viewMatrix` instead lives in the *columns* of `inverseViewMatrix`,
    // and the translation is the camera's world-space position.
    self.inverseViewMatrix = math.identity_mat4;
    self.inverseViewMatrix[0][0] = u[0];
    self.inverseViewMatrix[0][1] = u[1];
    self.inverseViewMatrix[0][2] = u[2];
    self.inverseViewMatrix[1][0] = v[0];
    self.inverseViewMatrix[1][1] = v[1];
    self.inverseViewMatrix[1][2] = v[2];
    self.inverseViewMatrix[2][0] = w[0];
    self.inverseViewMatrix[2][1] = w[1];
    self.inverseViewMatrix[2][2] = w[2];
    self.inverseViewMatrix[3][0] = position[0];
    self.inverseViewMatrix[3][1] = position[1];
    self.inverseViewMatrix[3][2] = position[2];
}

pub fn setViewTarget(
    self: *Self,
    position: Vec3,
    target: Vec3,
    up: Vec3,
) void {
    self.setViewDirection(position, target - position, up);
}

pub fn setViewYXZ(self: *Self, position: Vec3, rotation: Vec3) void {
    const c3 = @cos(rotation[2]);
    const s3 = @sin(rotation[2]);
    const c2 = @cos(rotation[0]);
    const s2 = @sin(rotation[0]);
    const c1 = @cos(rotation[1]);
    const s1 = @sin(rotation[1]);
    const u: Vec3 = .{
        c1 * c3 + s1 * s2 * s3,
        c2 * s3,
        c1 * s2 * s3 - c3 * s1,
    };
    const v: Vec3 = .{
        c3 * s1 * s2 - c1 * s3,
        c2 * c3,
        c1 * c3 * s2 + s1 * s3,
    };
    const w: Vec3 = .{
        c2 * s1,
        -s2,
        c1 * c2,
    };
    self.viewMatrix = math.identity_mat4;
    self.viewMatrix[0][0] = u[0];
    self.viewMatrix[1][0] = u[1];
    self.viewMatrix[2][0] = u[2];
    self.viewMatrix[0][1] = v[0];
    self.viewMatrix[1][1] = v[1];
    self.viewMatrix[2][1] = v[2];
    self.viewMatrix[0][2] = w[0];
    self.viewMatrix[1][2] = w[1];
    self.viewMatrix[2][2] = w[2];
    self.viewMatrix[3][0] = -math.dot3(u, position);
    self.viewMatrix[3][1] = -math.dot3(v, position);
    self.viewMatrix[3][2] = -math.dot3(w, position);

    // See `setViewDirection` for the rationale; the construction is
    // the same — write the camera basis into the columns and the
    // camera position into the translation row.
    self.inverseViewMatrix = math.identity_mat4;
    self.inverseViewMatrix[0][0] = u[0];
    self.inverseViewMatrix[0][1] = u[1];
    self.inverseViewMatrix[0][2] = u[2];
    self.inverseViewMatrix[1][0] = v[0];
    self.inverseViewMatrix[1][1] = v[1];
    self.inverseViewMatrix[1][2] = v[2];
    self.inverseViewMatrix[2][0] = w[0];
    self.inverseViewMatrix[2][1] = w[1];
    self.inverseViewMatrix[2][2] = w[2];
    self.inverseViewMatrix[3][0] = position[0];
    self.inverseViewMatrix[3][1] = position[1];
    self.inverseViewMatrix[3][2] = position[2];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Camera default view is the identity matrix" {
    const cam: Self = .{};
    const m = cam.getView();
    inline for (0..4) |col| {
        inline for (0..4) |row| {
            const expected: f32 = if (col == row) 1.0 else 0.0;
            try std.testing.expectApproxEqAbs(expected, m[col][row], 1e-6);
        }
    }
}

test "Camera.setViewDirection produces an orthonormal basis" {
    var cam: Self = .{};
    cam.setViewDirection(.{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 1.0 }, default_up);
    const m = cam.getView();

    // For position = origin, the translation row should be zero.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[3][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[3][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[3][2], 1e-6);

    const u: Vec3 = .{ m[0][0], m[1][0], m[2][0] };
    const v: Vec3 = .{ m[0][1], m[1][1], m[2][1] };
    const w: Vec3 = .{ m[0][2], m[1][2], m[2][2] };

    // Each basis vector must be unit length.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), math.dot3(u, u), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), math.dot3(v, v), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), math.dot3(w, w), 1e-6);

    // And mutually orthogonal.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), math.dot3(u, v), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), math.dot3(u, w), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), math.dot3(v, w), 1e-6);

    // For direction=(0,0,1) the forward (w) basis vector should be (0,0,1).
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), w[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), w[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), w[2], 1e-6);
}

test "Camera.setViewTarget delegates to setViewDirection" {
    var cam_a: Self = .{};
    var cam_b: Self = .{};
    const position: Vec3 = .{ -1.0, -2.0, -2.0 };
    const target: Vec3 = .{ 0.0, 0.0, 2.5 };
    cam_a.setViewTarget(position, target, default_up);
    cam_b.setViewDirection(position, target - position, default_up);
    const a = cam_a.getView();
    const b = cam_b.getView();
    inline for (0..4) |col| {
        inline for (0..4) |row| {
            try std.testing.expectApproxEqAbs(b[col][row], a[col][row], 1e-6);
        }
    }
}

test "Camera.setViewYXZ with zero rotation matches identity rotation" {
    var cam: Self = .{};
    cam.setViewYXZ(.{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 0.0 });
    const m = cam.getView();
    // Rotation submatrix should be the identity.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[1][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[2][2], 1e-6);
    // No translation expected.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[3][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[3][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[3][2], 1e-6);
}

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

test "Camera.setPerspectiveProjection scales X by 1/aspect for non-square aspect" {
    var cam: Self = .{};
    const fovy: f32 = std.math.pi / 2.0;
    const aspect: f32 = 16.0 / 9.0;
    cam.setPerspectiveProjection(fovy, aspect, 0.1, 100.0);
    const m = cam.getProjection();
    const tanHalf = std.math.tan(fovy / 2.0);
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0 / (aspect * tanHalf)),
        m[0][0],
        1e-6,
    );
    // Y entry should be independent of aspect.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / tanHalf), m[1][1], 1e-6);
}

test "Camera.setOrthographicProjection places translation in the last column" {
    var cam: Self = .{};
    // Non-symmetric box so the translation row is non-zero.
    cam.setOrthographicProjection(0.0, 4.0, 0.0, 2.0, 0.0, 10.0);
    const m = cam.getProjection();
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), m[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[1][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), m[2][2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), m[3][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), m[3][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[3][2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[3][3], 1e-6);
}

test "Camera.setViewDirection places -dot(basis, position) in the translation row" {
    var cam: Self = .{};
    const position: Vec3 = .{ 1.0, 2.0, 3.0 };
    cam.setViewDirection(position, .{ 0.0, 0.0, 1.0 }, default_up);
    const m = cam.getView();

    // With direction=(0,0,1) and up=(0,-1,0):
    //   w = (0,0,1), u = normalize(w x up) = (1, 0, 0), v = w x u = (0, 1, 0)
    const u: Vec3 = .{ 1.0, 0.0, 0.0 };
    const v: Vec3 = .{ 0.0, 1.0, 0.0 };
    const w: Vec3 = .{ 0.0, 0.0, 1.0 };

    try std.testing.expectApproxEqAbs(-math.dot3(u, position), m[3][0], 1e-6);
    try std.testing.expectApproxEqAbs(-math.dot3(v, position), m[3][1], 1e-6);
    try std.testing.expectApproxEqAbs(-math.dot3(w, position), m[3][2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[3][3], 1e-6);
}

test "Camera.setViewYXZ produces an orthonormal basis for non-zero rotation" {
    var cam: Self = .{};
    cam.setViewYXZ(.{ 0.0, 0.0, 0.0 }, .{ 0.3, -0.7, 1.2 });
    const m = cam.getView();

    const u: Vec3 = .{ m[0][0], m[1][0], m[2][0] };
    const v: Vec3 = .{ m[0][1], m[1][1], m[2][1] };
    const w: Vec3 = .{ m[0][2], m[1][2], m[2][2] };

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), math.dot3(u, u), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), math.dot3(v, v), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), math.dot3(w, w), 1e-5);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), math.dot3(u, v), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), math.dot3(u, w), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), math.dot3(v, w), 1e-5);

    // No position offset => zero translation row.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[3][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[3][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[3][2], 1e-6);
}

test "Camera.getInverseView is the inverse of getView (setViewYXZ)" {
    var cam: Self = .{};
    const position: Vec3 = .{ 1.5, -0.3, 4.0 };
    const rotation: Vec3 = .{ 0.3, -0.7, 1.2 };
    cam.setViewYXZ(position, rotation);

    const product = math.mul4(cam.getView(), cam.getInverseView());
    inline for (0..4) |col| {
        inline for (0..4) |row| {
            const expected: f32 = if (col == row) 1.0 else 0.0;
            try std.testing.expectApproxEqAbs(expected, product[col][row], 1e-5);
        }
    }

    // `inverseView[3].xyz` must recover the camera world-space position,
    // since the fragment shader reads it that way for specular lighting.
    try std.testing.expectApproxEqAbs(position[0], cam.getInverseView()[3][0], 1e-6);
    try std.testing.expectApproxEqAbs(position[1], cam.getInverseView()[3][1], 1e-6);
    try std.testing.expectApproxEqAbs(position[2], cam.getInverseView()[3][2], 1e-6);
}

test "Camera.getInverseView is the inverse of getView (setViewDirection)" {
    var cam: Self = .{};
    const position: Vec3 = .{ -2.0, 1.0, 0.5 };
    cam.setViewDirection(position, .{ 0.5, -0.25, 1.0 }, default_up);

    const product = math.mul4(cam.getView(), cam.getInverseView());
    inline for (0..4) |col| {
        inline for (0..4) |row| {
            const expected: f32 = if (col == row) 1.0 else 0.0;
            try std.testing.expectApproxEqAbs(expected, product[col][row], 1e-5);
        }
    }
}

test "Camera.getProjection / getView return the stored matrices" {
    var cam: Self = .{};
    cam.setOrthographicProjection(-2.0, 2.0, -1.0, 1.0, 0.0, 5.0);
    cam.setViewYXZ(.{ 1.0, 0.0, 0.0 }, .{ 0.0, 0.0, 0.0 });
    const projection = cam.getProjection();
    const view = cam.getView();
    inline for (0..4) |col| {
        inline for (0..4) |row| {
            try std.testing.expectEqual(cam.projectionMatrix[col][row], projection[col][row]);
            try std.testing.expectEqual(cam.viewMatrix[col][row], view[col][row]);
        }
    }
}
