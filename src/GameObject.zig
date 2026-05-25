const std = @import("std");

const c = @import("c.zig").c;
const cglm = @import("c.zig").cglm;
const Device = @import("Device.zig");
const Model = @import("Model.zig");
var currentId: u64 = 0;

const Self = @This();

id_t: u64,
model: Model,
color: cglm.vec3,
transform: TransformComponent,

pub const TransformComponent = extern struct {
    translation: cglm.vec3 = .{ 0, 0, 0 },
    scale: cglm.vec3 = .{ 1.0, 1.0, 1.0 },
    rotation: cglm.vec3 = .{ 0, 0, 0 },

    // Matrix corresponds to Translate * Ry * Rx * Rz * Scale
    // Rotations correspond to Tait-Bryan angles of Y(1), X(2), Z(3)
    // https://en.wikipedia.org/wiki/Euler_angles#Rotation_matrix
    pub fn mat4(self: *TransformComponent) cglm.mat4 {
        const c3 = std.math.cos(self.rotation[2]);
        const s3 = std.math.sin(self.rotation[2]);
        const c2 = std.math.cos(self.rotation[0]);
        const s2 = std.math.sin(self.rotation[0]);
        const c1 = std.math.cos(self.rotation[1]);
        const s1 = std.math.sin(self.rotation[1]);

        return cglm.mat4{
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
};

pub fn init(model: Model, color: cglm.vec3, transform: TransformComponent) !Self {
    const id = currentId;
    currentId += 1;
    return Self{
        .id_t = id,
        .model = model,
        .color = color,
        .transform = transform,
    };
}

pub fn deinit(self: *Self) void {
    self.model.deinit();
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
    // cglm mat4 is `vec4[4]` (column-major): m[col][row]
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
    try std.testing.expectEqual(@as(usize, 4), info.fields.len);
    try std.testing.expectEqual(u64, @FieldType(Self, "id_t"));
    try std.testing.expectEqual(Model, @FieldType(Self, "model"));
    try std.testing.expectEqual(cglm.vec3, @FieldType(Self, "color"));
    try std.testing.expectEqual(TransformComponent, @FieldType(Self, "transform"));
}

test "GameObject.init assigns strictly increasing ids and getId matches id_t" {
    var device: Device = undefined;
    const model = Model{ .device = &device, .vertexCount = 0 };

    const a = try Self.init(model, .{ 1, 0, 0 }, .{});
    const b = try Self.init(model, .{ 0, 1, 0 }, .{});
    const cc = try Self.init(model, .{ 0, 0, 1 }, .{});

    try std.testing.expect(b.id_t > a.id_t);
    try std.testing.expect(cc.id_t > b.id_t);
    try std.testing.expectEqual(a.id_t, a.getId());
    try std.testing.expectEqual(b.id_t, b.getId());
    try std.testing.expectEqual(cc.id_t, cc.getId());
}

test "GameObject.init copies color and transform fields" {
    var device: Device = undefined;
    const model = Model{ .device = &device, .vertexCount = 0 };

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
