const std = @import("std");

const c = @import("c.zig").c;
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Device = @import("Device.zig");
const Model = @import("Model.zig");
var currentId: u64 = 0;

const Self = @This();

/// Hash-map keyed by `id_t`, mirroring `LveGameObject::Map` in the
/// upstream C++ tutorial (`std::unordered_map<id_t, LveGameObject>`).
/// Iteration order is unspecified, matching `std::unordered_map`.
pub const Map = std.AutoHashMapUnmanaged(u64, Self);

id_t: u64,
// The model is optional because some game objects exist purely to carry
// a `TransformComponent` (e.g. the camera "viewer" object that is driven
// by the keyboard controller). `null` means "nothing to render".
model: ?Model,
color: Vec3,
transform: TransformComponent,
/// Optional point-light component. When non-null the object is
/// treated as a point light by `PointLightSystem` (which mirrors
/// `LveGameObject::pointLight` in the upstream tutorial — an
/// optional `std::unique_ptr<PointLightComponent>`).
pointLight: ?PointLightComponent = null,
/// Basename of the embedded diffuse texture this object should be
/// rendered with (e.g. `"stonefloor01_color_rgba.ktx"`). `null`
/// means "no named texture" — `FirstApp` will bind a 1×1 white
/// fallback at `set = 1, binding = 0` so the existing shader path
/// still produces the unlit vertex color. The string lives in
/// static program data (`@embedFile` keys), so no allocation/free
/// is needed.
textureName: ?[]const u8 = null,
/// Basename of the embedded tangent-space normal map (e.g.
/// `"stonefloor01_normal_rgba.ktx"`). `null` means "no normal
/// map" — `FirstApp` will bind a 1×1 flat-normal fallback at
/// `set = 1, binding = 1` (RGB = (128, 128, 255), which decodes to
/// the tangent-space `+Z` unit vector and thus leaves the
/// interpolated geometric normal unchanged in the fragment
/// shader). Same lifetime / ownership story as `textureName`.
normalName: ?[]const u8 = null,
/// Descriptor set bound at `set = 1` by `SimpleRenderSystem` (two
/// `COMBINED_IMAGE_SAMPLER` bindings covering the chosen diffuse
/// + normal `Texture`s). Assigned in `FirstApp.run` after the
/// global pool and the per-material descriptor sets are built;
/// render-system code asserts it is non-null for any object with a
/// `model`.
textureDescriptorSet: c.VkDescriptorSet = null,

pub const PointLightComponent = struct {
    lightIntensity: f32 = 1.0,
};

pub const TransformComponent = struct {
    translation: Vec3 = .{ 0, 0, 0 },
    scale: Vec3 = .{ 1.0, 1.0, 1.0 },
    rotation: Vec3 = .{ 0, 0, 0 },

    // Matrix corresponds to Translate * Ry * Rx * Rz * Scale
    // Rotations correspond to Tait-Bryan angles of Y(1), X(2), Z(3)
    // https://en.wikipedia.org/wiki/Euler_angles#Rotation_matrix
    pub fn mat4(self: *TransformComponent) Mat4 {
        const c3 = std.math.cos(self.rotation[2]);
        const s3 = std.math.sin(self.rotation[2]);
        const c2 = std.math.cos(self.rotation[0]);
        const s2 = std.math.sin(self.rotation[0]);
        const c1 = std.math.cos(self.rotation[1]);
        const s1 = std.math.sin(self.rotation[1]);

        return Mat4{
            .{
                self.scale[0] * (c1 * c3 + s1 * s2 * s3),
                self.scale[0] * (c2 * s3),
                self.scale[0] * (c1 * s2 * s3 - c3 * s1),
                0.0,
            },
            .{
                self.scale[1] * (c3 * s1 * s2 - c1 * s3),
                self.scale[1] * (c2 * c3),
                self.scale[1] * (c1 * c3 * s2 + s1 * s3),
                0.0,
            },
            .{
                self.scale[2] * (c2 * s1),
                self.scale[2] * (-s2),
                self.scale[2] * (c1 * c2),
                0.0,
            },
            .{ self.translation[0], self.translation[1], self.translation[2], 1.0 },
        };
    }

    /// Returns the normal matrix corresponding to `mat4()`'s rotation
    /// and scale (translation is irrelevant for normals). Computed
    /// analytically as `R * diag(1/scale)`, i.e. the transpose of the
    /// inverse of the upper 3x3, which only works when the model
    /// matrix has uniform-or-axis-aligned scaling. Mirrors
    /// `TransformComponent::normalMatrix` in the upstream C++ tutorial.
    ///
    /// The result is returned as a `Mat4` (rather than a `Mat3`) to
    /// match the push-constant layout the shader expects — the shader
    /// then does `mat3(push.normalMatrix) * normal`. The 4th row/col
    /// is identity-extended just like `glm::mat4(glm::mat3)`.
    pub fn normalMatrix(self: *TransformComponent) Mat4 {
        const c3 = std.math.cos(self.rotation[2]);
        const s3 = std.math.sin(self.rotation[2]);
        const c2 = std.math.cos(self.rotation[0]);
        const s2 = std.math.sin(self.rotation[0]);
        const c1 = std.math.cos(self.rotation[1]);
        const s1 = std.math.sin(self.rotation[1]);

        const inv: Vec3 = .{
            1.0 / self.scale[0],
            1.0 / self.scale[1],
            1.0 / self.scale[2],
        };

        return Mat4{
            .{
                inv[0] * (c1 * c3 + s1 * s2 * s3),
                inv[0] * (c2 * s3),
                inv[0] * (c1 * s2 * s3 - c3 * s1),
                0.0,
            },
            .{
                inv[1] * (c3 * s1 * s2 - c1 * s3),
                inv[1] * (c2 * c3),
                inv[1] * (c1 * c3 * s2 + s1 * s3),
                0.0,
            },
            .{
                inv[2] * (c2 * s1),
                inv[2] * (-s2),
                inv[2] * (c1 * c2),
                0.0,
            },
            .{ 0.0, 0.0, 0.0, 1.0 },
        };
    }
};

pub fn init(model: Model, color: Vec3, transform: TransformComponent) !Self {
    const id = currentId;
    currentId += 1;
    return Self{
        .id_t = id,
        .model = model,
        .color = color,
        .transform = transform,
    };
}

/// Construct a game object without a renderable model. Mirrors the
/// `LveGameObject::createGameObject()` factory in the C++ tutorial and
/// is used for non-rendered entities such as the camera "viewer" object
/// that only carries a `TransformComponent`.
pub fn createGameObject() Self {
    const id = currentId;
    currentId += 1;
    return Self{
        .id_t = id,
        .model = null,
        .color = .{ 0, 0, 0 },
        .transform = .{},
    };
}

/// Construct a model-less object representing a point light.
/// Mirrors `LveGameObject::makePointLight` in the upstream tutorial:
/// the radius is stored in `transform.scale[0]` and the
/// `pointLight` component carries the light intensity. Color is the
/// object's `color` field, mapped 1:1 onto the light's RGB.
pub fn makePointLight(intensity: f32, radius: f32, color: Vec3) Self {
    var obj = createGameObject();
    obj.color = color;
    obj.transform.scale[0] = radius;
    obj.pointLight = .{ .lightIntensity = intensity };
    return obj;
}

pub fn deinit(self: *Self) void {
    if (self.model) |*m| m.deinit();
}

pub fn getId(self: Self) u64 {
    return self.id_t;
}

test "TransformComponent default values" {
    const t = TransformComponent{};
    try std.testing.expectEqual(@as(f32, 0.0), t.translation[0]);
    try std.testing.expectEqual(@as(f32, 0.0), t.translation[1]);
    try std.testing.expectEqual(@as(f32, 0.0), t.translation[2]);
    try std.testing.expectEqual(@as(f32, 1.0), t.scale[0]);
    try std.testing.expectEqual(@as(f32, 1.0), t.scale[1]);
    try std.testing.expectEqual(@as(f32, 1.0), t.scale[2]);
    try std.testing.expectEqual(@as(f32, 0.0), t.rotation[0]);
    try std.testing.expectEqual(@as(f32, 0.0), t.rotation[1]);
    try std.testing.expectEqual(@as(f32, 0.0), t.rotation[2]);
}

test "TransformComponent.mat4 returns identity for rotation=0 and scale=1" {
    var t = TransformComponent{};
    const m = t.mat4();
    // Mat4 is `[4]Vec4` (column-major): m[col][row]
    inline for (0..4) |col| {
        inline for (0..4) |row| {
            const expected: f32 = if (col == row) 1.0 else 0.0;
            try std.testing.expectApproxEqAbs(expected, m[col][row], 1e-6);
        }
    }
}

test "TransformComponent.mat4 applies scale on the diagonal when rotation=0" {
    var t = TransformComponent{ .scale = .{ 2.0, 3.0, 4.0 } };
    const m = t.mat4();
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), m[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), m[1][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), m[2][2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[3][3], 1e-6);
}

test "TransformComponent.mat4 places translation in the last column" {
    var t = TransformComponent{ .translation = .{ 1.5, -2.5, 3.5 } };
    const m = t.mat4();
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), m[3][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -2.5), m[3][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.5), m[3][2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[3][3], 1e-6);
}

test "GameObject has expected fields" {
    const info = @typeInfo(Self).@"struct";
    try std.testing.expectEqual(@as(usize, 8), info.fields.len);
    try std.testing.expectEqual(u64, @FieldType(Self, "id_t"));
    try std.testing.expectEqual(?Model, @FieldType(Self, "model"));
    try std.testing.expectEqual(Vec3, @FieldType(Self, "color"));
    try std.testing.expectEqual(TransformComponent, @FieldType(Self, "transform"));
    try std.testing.expectEqual(?PointLightComponent, @FieldType(Self, "pointLight"));
    try std.testing.expectEqual(?[]const u8, @FieldType(Self, "textureName"));
    try std.testing.expectEqual(?[]const u8, @FieldType(Self, "normalName"));
    try std.testing.expectEqual(c.VkDescriptorSet, @FieldType(Self, "textureDescriptorSet"));
}

test "GameObject.makePointLight sets the pointLight component and radius" {
    const obj = Self.makePointLight(0.2, 0.1, .{ 1, 0.5, 0.25 });
    try std.testing.expect(obj.model == null);
    try std.testing.expect(obj.pointLight != null);
    try std.testing.expectEqual(@as(f32, 0.2), obj.pointLight.?.lightIntensity);
    try std.testing.expectEqual(@as(f32, 0.1), obj.transform.scale[0]);
    try std.testing.expectEqual(@as(f32, 1.0), obj.color[0]);
    try std.testing.expectEqual(@as(f32, 0.5), obj.color[1]);
    try std.testing.expectEqual(@as(f32, 0.25), obj.color[2]);
}

test "GameObject default pointLight is null for regular game objects" {
    const obj = Self.createGameObject();
    try std.testing.expect(obj.pointLight == null);
}

test "GameObject.init assigns strictly increasing ids and getId matches id_t" {
    // SAFETY: GameObject.init never dereferences the model's device pointer
    // or its buffer handles; it only stores the model by value.
    var device: Device = undefined;
    const model = Model{
        .device = &device,
        .vertexCount = 0,
        // SAFETY: not read by GameObject.init.
        .vertexBuffer = undefined,
    };

    const a = try Self.init(model, .{ 1, 0, 0 }, .{});
    const b = try Self.init(model, .{ 0, 1, 0 }, .{});
    const cc = try Self.init(model, .{ 0, 0, 1 }, .{});

    try std.testing.expect(b.id_t > a.id_t);
    try std.testing.expect(cc.id_t > b.id_t);
    try std.testing.expectEqual(a.id_t, a.getId());
    try std.testing.expectEqual(b.id_t, b.getId());
    try std.testing.expectEqual(cc.id_t, cc.getId());
}

test "TransformComponent.mat4 rotation submatrix is orthonormal for pure rotation" {
    var t = TransformComponent{ .rotation = .{ 0.4, -1.1, 0.7 } };
    const m = t.mat4();

    // Columns 0..2 of the rotation submatrix (excluding the bottom row).
    const c0: [3]f32 = .{ m[0][0], m[0][1], m[0][2] };
    const c1: [3]f32 = .{ m[1][0], m[1][1], m[1][2] };
    const c2: [3]f32 = .{ m[2][0], m[2][1], m[2][2] };

    inline for ([_][3]f32{ c0, c1, c2 }) |col| {
        const len2 = col[0] * col[0] + col[1] * col[1] + col[2] * col[2];
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), len2, 1e-5);
    }
    const dot01 = c0[0] * c1[0] + c0[1] * c1[1] + c0[2] * c1[2];
    const dot02 = c0[0] * c2[0] + c0[1] * c2[1] + c0[2] * c2[2];
    const dot12 = c1[0] * c2[0] + c1[1] * c2[1] + c1[2] * c2[2];
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dot01, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dot02, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dot12, 1e-5);

    // Bottom row (homogeneous) must remain (0,0,0,1).
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[0][3], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[1][3], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[2][3], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[3][3], 1e-6);
}

test "TransformComponent.mat4 combines translation and scale (rotation=0)" {
    var t = TransformComponent{
        .translation = .{ 1.0, 2.0, 3.0 },
        .scale = .{ 4.0, 5.0, 6.0 },
    };
    const m = t.mat4();
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), m[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), m[1][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), m[2][2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[3][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), m[3][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), m[3][2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[3][3], 1e-6);
}

test "TransformComponent.mat4 is deterministic for identical inputs" {
    var a = TransformComponent{
        .translation = .{ -0.5, 1.5, 2.0 },
        .scale = .{ 0.75, 0.75, 0.75 },
        .rotation = .{ 0.2, 0.4, -0.6 },
    };
    var b = TransformComponent{
        .translation = .{ -0.5, 1.5, 2.0 },
        .scale = .{ 0.75, 0.75, 0.75 },
        .rotation = .{ 0.2, 0.4, -0.6 },
    };
    const ma = a.mat4();
    const mb = b.mat4();
    inline for (0..4) |col| {
        inline for (0..4) |row| {
            try std.testing.expectEqual(ma[col][row], mb[col][row]);
        }
    }
}

test "GameObject.createGameObject yields a model-less object with default transform" {
    const obj = Self.createGameObject();

    try std.testing.expect(obj.model == null);
    try std.testing.expectEqual(@as(f32, 0.0), obj.color[0]);
    try std.testing.expectEqual(@as(f32, 0.0), obj.color[1]);
    try std.testing.expectEqual(@as(f32, 0.0), obj.color[2]);
    try std.testing.expectEqual(@as(f32, 0.0), obj.transform.translation[0]);
    try std.testing.expectEqual(@as(f32, 1.0), obj.transform.scale[0]);
    try std.testing.expectEqual(@as(f32, 0.0), obj.transform.rotation[0]);
}

test "GameObject.createGameObject still assigns strictly increasing ids" {
    const a = Self.createGameObject();
    const b = Self.createGameObject();
    try std.testing.expect(b.id_t > a.id_t);
}

test "TransformComponent.normalMatrix is identity for rotation=0 and scale=1" {
    var t = TransformComponent{};
    const n = t.normalMatrix();
    inline for (0..4) |col| {
        inline for (0..4) |row| {
            const expected: f32 = if (col == row) 1.0 else 0.0;
            try std.testing.expectApproxEqAbs(expected, n[col][row], 1e-6);
        }
    }
}

test "TransformComponent.normalMatrix scales upper 3x3 by 1/scale when rotation=0" {
    var t = TransformComponent{ .scale = .{ 2.0, 4.0, 8.0 } };
    const n = t.normalMatrix();
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), n[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), n[1][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), n[2][2], 1e-6);
    // Off-diagonal upper 3x3 entries are zero.
    inline for (0..3) |col| {
        inline for (0..3) |row| {
            if (col == row) continue;
            try std.testing.expectApproxEqAbs(@as(f32, 0.0), n[col][row], 1e-6);
        }
    }
    // 4th row/col is identity-extended.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), n[3][3], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), n[3][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), n[3][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), n[3][2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), n[0][3], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), n[1][3], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), n[2][3], 1e-6);
}

test "TransformComponent.normalMatrix upper 3x3 matches mat4 upper 3x3 for uniform scale=1" {
    var t = TransformComponent{ .rotation = .{ 0.3, -0.8, 1.2 } };
    const m = t.mat4();
    const n = t.normalMatrix();
    // With scale=1 the normal matrix equals the rotation block of mat4.
    inline for (0..3) |col| {
        inline for (0..3) |row| {
            try std.testing.expectApproxEqAbs(m[col][row], n[col][row], 1e-6);
        }
    }
}

test "TransformComponent.normalMatrix preserves normal lengths for uniform scale" {
    // With uniform scale, R * diag(1/s) applied to a unit-length vector
    // produces a vector of length 1/s (per-axis equal). After GLSL
    // `normalize(...)` this still yields a unit vector — verify the
    // pre-normalize length matches 1/s exactly.
    var t = TransformComponent{
        .rotation = .{ 0.2, 0.4, -0.6 },
        .scale = .{ 2.0, 2.0, 2.0 },
    };
    const n = t.normalMatrix();
    // Apply n's upper-3x3 to (1, 0, 0).
    const v0: math.Vec3 = .{ n[0][0], n[0][1], n[0][2] };
    const len = math.length3(v0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), len, 1e-6);
}

test "GameObject.init copies color and transform fields" {
    // SAFETY: GameObject.init never dereferences the model's device pointer
    // or its buffer handles; it only stores the model by value.
    var device: Device = undefined;
    const model = Model{
        .device = &device,
        .vertexCount = 0,
        // SAFETY: not read by GameObject.init.
        .vertexBuffer = undefined,
    };

    const transform: TransformComponent = .{
        .translation = .{ 0.5, -0.25, 1.0 },
        .scale = .{ 2.0, 0.5, 1.0 },
        .rotation = .{ 0.1, 1.25, -0.5 },
    };
    const obj = try Self.init(model, .{ 0.1, 0.2, 0.3 }, transform);

    try std.testing.expectEqual(@as(f32, 0.1), obj.color[0]);
    try std.testing.expectEqual(@as(f32, 0.2), obj.color[1]);
    try std.testing.expectEqual(@as(f32, 0.3), obj.color[2]);
    try std.testing.expectEqual(transform.translation[0], obj.transform.translation[0]);
    try std.testing.expectEqual(transform.translation[1], obj.transform.translation[1]);
    try std.testing.expectEqual(transform.translation[2], obj.transform.translation[2]);
    try std.testing.expectEqual(transform.scale[0], obj.transform.scale[0]);
    try std.testing.expectEqual(transform.scale[1], obj.transform.scale[1]);
    try std.testing.expectEqual(transform.scale[2], obj.transform.scale[2]);
    try std.testing.expectEqual(transform.rotation[0], obj.transform.rotation[0]);
    try std.testing.expectEqual(transform.rotation[1], obj.transform.rotation[1]);
    try std.testing.expectEqual(transform.rotation[2], obj.transform.rotation[2]);
}
