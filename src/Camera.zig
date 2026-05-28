const std = @import("std");

const cglm = @import("c.zig").cglm;

const Self = @This();

const identity_mat4: cglm.mat4 = .{
    .{ 1.0, 0.0, 0.0, 0.0 },
    .{ 0.0, 1.0, 0.0, 0.0 },
    .{ 0.0, 0.0, 1.0, 0.0 },
    .{ 0.0, 0.0, 0.0, 1.0 },
};

// Column-major 4x4 projection matrix, identity by default.
projectionMatrix: cglm.mat4 = identity_mat4,
// Column-major 4x4 view matrix, identity by default.
viewMatrix: cglm.mat4 = identity_mat4,

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
    self.projectionMatrix = identity_mat4;
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

pub fn getView(self: *const Self) cglm.mat4 {
    return self.viewMatrix;
}

// ---------------------------------------------------------------------------
// Small vec3 helpers. Implemented inline so this module stays a pure Zig
// translation of the GLM math used by the C++ tutorial; no cglm runtime
// dependency is required for these basic operations.
// ---------------------------------------------------------------------------

inline fn vec3Dot(a: cglm.vec3, b: cglm.vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

inline fn vec3Cross(a: cglm.vec3, b: cglm.vec3) cglm.vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

inline fn vec3Normalize(v: cglm.vec3) cglm.vec3 {
    const len = @sqrt(vec3Dot(v, v));
    // Match GLM behavior: normalizing a zero-length vector is undefined.
    // `std.debug.assert` is checked in Debug and ReleaseSafe builds (and
    // stripped in ReleaseFast / ReleaseSmall), so callers get a clear
    // error in any build that opts into safety.
    std.debug.assert(len > 0.0);
    const inv = 1.0 / len;
    return .{ v[0] * inv, v[1] * inv, v[2] * inv };
}

pub const default_up: cglm.vec3 = .{ 0.0, -1.0, 0.0 };

pub fn setViewDirection(
    self: *Self,
    position: cglm.vec3,
    direction: cglm.vec3,
    up: cglm.vec3,
) void {
    const w = vec3Normalize(direction);
    const u = vec3Normalize(vec3Cross(w, up));
    const v = vec3Cross(w, u);

    self.viewMatrix = identity_mat4;
    self.viewMatrix[0][0] = u[0];
    self.viewMatrix[1][0] = u[1];
    self.viewMatrix[2][0] = u[2];
    self.viewMatrix[0][1] = v[0];
    self.viewMatrix[1][1] = v[1];
    self.viewMatrix[2][1] = v[2];
    self.viewMatrix[0][2] = w[0];
    self.viewMatrix[1][2] = w[1];
    self.viewMatrix[2][2] = w[2];
    self.viewMatrix[3][0] = -vec3Dot(u, position);
    self.viewMatrix[3][1] = -vec3Dot(v, position);
    self.viewMatrix[3][2] = -vec3Dot(w, position);
}

pub fn setViewTarget(
    self: *Self,
    position: cglm.vec3,
    target: cglm.vec3,
    up: cglm.vec3,
) void {
    const direction: cglm.vec3 = .{
        target[0] - position[0],
        target[1] - position[1],
        target[2] - position[2],
    };
    self.setViewDirection(position, direction, up);
}

pub fn setViewYXZ(self: *Self, position: cglm.vec3, rotation: cglm.vec3) void {
    const c3 = @cos(rotation[2]);
    const s3 = @sin(rotation[2]);
    const c2 = @cos(rotation[0]);
    const s2 = @sin(rotation[0]);
    const c1 = @cos(rotation[1]);
    const s1 = @sin(rotation[1]);
    const u: cglm.vec3 = .{
        c1 * c3 + s1 * s2 * s3,
        c2 * s3,
        c1 * s2 * s3 - c3 * s1,
    };
    const v: cglm.vec3 = .{
        c3 * s1 * s2 - c1 * s3,
        c2 * c3,
        c1 * c3 * s2 + s1 * s3,
    };
    const w: cglm.vec3 = .{
        c2 * s1,
        -s2,
        c1 * c2,
    };
    self.viewMatrix = identity_mat4;
    self.viewMatrix[0][0] = u[0];
    self.viewMatrix[1][0] = u[1];
    self.viewMatrix[2][0] = u[2];
    self.viewMatrix[0][1] = v[0];
    self.viewMatrix[1][1] = v[1];
    self.viewMatrix[2][1] = v[2];
    self.viewMatrix[0][2] = w[0];
    self.viewMatrix[1][2] = w[1];
    self.viewMatrix[2][2] = w[2];
    self.viewMatrix[3][0] = -vec3Dot(u, position);
    self.viewMatrix[3][1] = -vec3Dot(v, position);
    self.viewMatrix[3][2] = -vec3Dot(w, position);
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

    // The view matrix stores the basis vectors u (right), v (up'), w
    // (forward) such that `view * world_vec` rotates a world vector into
    // camera space. Because the basis lives in the rows of the rotation
    // sub-matrix in our column-major layout, row `i` is the vector whose
    // components are `m[0][i], m[1][i], m[2][i]`.
    const u: cglm.vec3 = .{ m[0][0], m[1][0], m[2][0] };
    const v: cglm.vec3 = .{ m[0][1], m[1][1], m[2][1] };
    const w: cglm.vec3 = .{ m[0][2], m[1][2], m[2][2] };

    // Each basis vector must be unit length.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), vec3Dot(u, u), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), vec3Dot(v, v), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), vec3Dot(w, w), 1e-6);

    // And mutually orthogonal.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), vec3Dot(u, v), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), vec3Dot(u, w), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), vec3Dot(v, w), 1e-6);

    // For direction=(0,0,1) the forward (w) basis vector should be (0,0,1).
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), w[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), w[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), w[2], 1e-6);
}

test "Camera.setViewTarget delegates to setViewDirection" {
    var cam_a: Self = .{};
    var cam_b: Self = .{};
    const position: cglm.vec3 = .{ -1.0, -2.0, -2.0 };
    const target: cglm.vec3 = .{ 0.0, 0.0, 2.5 };
    const direction: cglm.vec3 = .{
        target[0] - position[0],
        target[1] - position[1],
        target[2] - position[2],
    };
    cam_a.setViewTarget(position, target, default_up);
    cam_b.setViewDirection(position, direction, default_up);
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
