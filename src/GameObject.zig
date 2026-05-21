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
transform2d: Transform2dComponent,

pub const Transform2dComponent = extern struct {
    translation: cglm.vec2 = .{ 0, 0 }, // position offset
    scale: cglm.vec2 = .{ 1.0, 1.0 },
    rotation: f32 = 0.0,

    pub fn mat2(self: *Transform2dComponent) cglm.mat2 {
        var scaleMat: cglm.mat2 = .{ .{ self.scale[0], 0.0 }, .{ 0.0, self.scale[1] } };
        var rotationMat: cglm.mat2 = .{
            .{ std.math.cos(self.rotation), std.math.sin(self.rotation) },
            .{ -std.math.sin(self.rotation), std.math.cos(self.rotation) },
        };

        var result: cglm.mat2 = undefined;
        cglm.glm_mat2_mul(&rotationMat, &scaleMat, &result);
        return result;
    }
};

pub fn init(model: Model, color: cglm.vec3, transform: Transform2dComponent) !Self {
    const id = currentId;
    currentId += 1;
    return Self{
        .id_t = id,
        .model = model,
        .color = color,
        .transform2d = transform,
    };
}

pub fn deinit(self: *Self) void {
    self.model.deinit();
}

pub fn getId(self: Self) u64 {
    return self.id_t;
}

test "Transform2dComponent default values" {
    const t = Transform2dComponent{};
    try std.testing.expectEqual(@as(f32, 0.0), t.translation[0]);
    try std.testing.expectEqual(@as(f32, 0.0), t.translation[1]);
    try std.testing.expectEqual(@as(f32, 1.0), t.scale[0]);
    try std.testing.expectEqual(@as(f32, 1.0), t.scale[1]);
    try std.testing.expectEqual(@as(f32, 0.0), t.rotation);
}

test "Transform2dComponent.mat2 returns identity for rotation=0 and scale=1" {
    var t = Transform2dComponent{};
    const m = t.mat2();
    // cglm mat2 is `vec2[2]` (column-major): m[col][row]
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[0][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[1][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[1][1], 1e-6);
}

test "Transform2dComponent.mat2 applies scale on the diagonal when rotation=0" {
    var t = Transform2dComponent{ .scale = .{ 2.0, 3.0 } };
    const m = t.mat2();
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), m[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[0][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m[1][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), m[1][1], 1e-6);
}

test "Transform2dComponent.mat2 applies rotation when scale=1" {
    const angle: f32 = std.math.pi / 2.0;
    var t = Transform2dComponent{ .rotation = angle };
    const m = t.mat2();
    // result = rotation * scale, with scale = identity
    try std.testing.expectApproxEqAbs(std.math.cos(angle), m[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(std.math.sin(angle), m[0][1], 1e-6);
    try std.testing.expectApproxEqAbs(-std.math.sin(angle), m[1][0], 1e-6);
    try std.testing.expectApproxEqAbs(std.math.cos(angle), m[1][1], 1e-6);
}

test "GameObject has expected fields" {
    const info = @typeInfo(Self).@"struct";
    try std.testing.expectEqual(@as(usize, 4), info.fields.len);
    try std.testing.expectEqual(u64, @FieldType(Self, "id_t"));
    try std.testing.expectEqual(Model, @FieldType(Self, "model"));
    try std.testing.expectEqual(cglm.vec3, @FieldType(Self, "color"));
    try std.testing.expectEqual(Transform2dComponent, @FieldType(Self, "transform2d"));
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

    const transform: Transform2dComponent = .{
        .translation = .{ 0.5, -0.25 },
        .scale = .{ 2.0, 0.5 },
        .rotation = 1.25,
    };
    const obj = try Self.init(model, .{ 0.1, 0.2, 0.3 }, transform);

    try std.testing.expectEqual(@as(f32, 0.1), obj.color[0]);
    try std.testing.expectEqual(@as(f32, 0.2), obj.color[1]);
    try std.testing.expectEqual(@as(f32, 0.3), obj.color[2]);
    try std.testing.expectEqual(transform.translation[0], obj.transform2d.translation[0]);
    try std.testing.expectEqual(transform.translation[1], obj.transform2d.translation[1]);
    try std.testing.expectEqual(transform.scale[0], obj.transform2d.scale[0]);
    try std.testing.expectEqual(transform.scale[1], obj.transform2d.scale[1]);
    try std.testing.expectEqual(transform.rotation, obj.transform2d.rotation);
}
