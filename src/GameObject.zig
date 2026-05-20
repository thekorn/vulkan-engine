const std = @import("std");

const c = @import("c.zig").c;
const cglm = @import("c.zig").cglm;
const Model = @import("Model.zig");
var currentId: u64 = 0;

const Self = @This();

id_t: u64,
model: Model,
color: cglm.vec3,
transform2d: Transform2dComponent,

pub const Transform2dComponent = extern struct {
    translation: cglm.vec2, // position offset

    pub fn mat2() cglm.mat2 {
        // TODO: should be cglm.GLM_MAT2_IDENTITY
        return .{ .{ 1.0, 0.0 }, .{ 0.0, 1.0 } };
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
