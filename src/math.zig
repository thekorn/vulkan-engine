// Tiny linear-algebra helpers built on top of the built-in
// `@Vector` SIMD types.
//
// Conventions:
//   * `Mat4` is column-major (`[4]Vec4`) – column `c`, row `r` is
//     `m[c][r]`. This matches the GLSL convention used by the
//     shaders and the layout previously produced by the C math
//     library used in this project.
//   * Matrix multiplication `mul4(a, b)` performs `a * b` in the
//     usual column-major sense.

const std = @import("std");

pub const Vec2 = @Vector(2, f32);
pub const Vec3 = @Vector(3, f32);
pub const Vec4 = @Vector(4, f32);

/// Column-major 4x4 matrix.
pub const Mat4 = [4]Vec4;

pub const identity_mat4: Mat4 = .{
    .{ 1.0, 0.0, 0.0, 0.0 },
    .{ 0.0, 1.0, 0.0, 0.0 },
    .{ 0.0, 0.0, 1.0, 0.0 },
    .{ 0.0, 0.0, 0.0, 1.0 },
};

// ---------------------------------------------------------------------------
// Vec3 helpers
// ---------------------------------------------------------------------------

pub inline fn dot3(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

pub inline fn length3(v: Vec3) f32 {
    return @sqrt(dot3(v, v));
}

/// Returns `v / |v|`. Asserts `|v| > 0`; matches GLM behavior where
/// normalizing a zero-length vector is undefined.
pub inline fn normalize3(v: Vec3) Vec3 {
    const len = length3(v);
    std.debug.assert(len > 0.0);
    return v / @as(Vec3, @splat(len));
}

pub inline fn cross3(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

// ---------------------------------------------------------------------------
// Mat4 helpers
// ---------------------------------------------------------------------------

/// Column-major 4x4 matrix multiplication: `result = a * b`.
pub fn mul4(a: Mat4, b: Mat4) Mat4 {
    var result: Mat4 = undefined;
    inline for (0..4) |col| {
        const b0: Vec4 = @splat(b[col][0]);
        const b1: Vec4 = @splat(b[col][1]);
        const b2: Vec4 = @splat(b[col][2]);
        const b3: Vec4 = @splat(b[col][3]);
        result[col] = a[0] * b0 + a[1] * b1 + a[2] * b2 + a[3] * b3;
    }
    return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "dot3 computes the dot product" {
    const a: Vec3 = .{ 1.0, 2.0, 3.0 };
    const b: Vec3 = .{ -1.0, 0.5, 2.0 };
    try std.testing.expectApproxEqAbs(@as(f32, -1.0 + 1.0 + 6.0), dot3(a, b), 1e-6);
}

test "length3 of (3,0,4) is 5" {
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), length3(.{ 3.0, 0.0, 4.0 }), 1e-6);
}

test "normalize3 returns a unit vector" {
    const n = normalize3(.{ 3.0, 0.0, 4.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), n[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), n[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), n[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dot3(n, n), 1e-6);
}

test "cross3 of basis vectors yields the third basis vector" {
    const x: Vec3 = .{ 1.0, 0.0, 0.0 };
    const y: Vec3 = .{ 0.0, 1.0, 0.0 };
    const z = cross3(x, y);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), z[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), z[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), z[2], 1e-6);
}

test "cross3 is anti-commutative" {
    const a: Vec3 = .{ 1.0, 2.0, 3.0 };
    const b: Vec3 = .{ -2.0, 0.5, 4.0 };
    const ab = cross3(a, b);
    const ba = cross3(b, a);
    inline for (0..3) |i| {
        try std.testing.expectApproxEqAbs(-ab[i], ba[i], 1e-6);
    }
}

test "mul4 with identity returns the other matrix" {
    const m: Mat4 = .{
        .{ 1.0, 2.0, 3.0, 4.0 },
        .{ 5.0, 6.0, 7.0, 8.0 },
        .{ 9.0, 10.0, 11.0, 12.0 },
        .{ 13.0, 14.0, 15.0, 16.0 },
    };
    const r = mul4(identity_mat4, m);
    inline for (0..4) |col| {
        inline for (0..4) |row| {
            try std.testing.expectEqual(m[col][row], r[col][row]);
        }
    }
    const r2 = mul4(m, identity_mat4);
    inline for (0..4) |col| {
        inline for (0..4) |row| {
            try std.testing.expectEqual(m[col][row], r2[col][row]);
        }
    }
}

test "mul4 matches a hand-computed product (column-major)" {
    // a = diag(2, 3, 4, 1); b = identity with translation (5, 6, 7).
    const a: Mat4 = .{
        .{ 2.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 3.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 4.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 1.0 },
    };
    var b: Mat4 = identity_mat4;
    b[3] = .{ 5.0, 6.0, 7.0, 1.0 };

    // a * b should scale the translation column by the diagonal entries.
    const r = mul4(a, b);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), r[3][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 18.0), r[3][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 28.0), r[3][2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), r[3][3], 1e-6);
    // Diagonal preserved.
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), r[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), r[1][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), r[2][2], 1e-6);
}

test "identity_mat4 is the identity matrix" {
    inline for (0..4) |col| {
        inline for (0..4) |row| {
            const expected: f32 = if (col == row) 1.0 else 0.0;
            try std.testing.expectEqual(expected, identity_mat4[col][row]);
        }
    }
}
