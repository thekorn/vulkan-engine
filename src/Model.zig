const std = @import("std");

const c = @import("c.zig").c;
const cglm = @import("c.zig").cglm;
const Device = @import("Device.zig");
const ArrayList = std.ArrayList;

const Self = @This();
device: *Device,

pub const Vertex = struct {
    position: cglm.vec2,
};

pub fn init(device: *Device, vertices: *ArrayList(Vertex)) !Self {
    //createVertexBuffers();
    _ = vertices;
    return .{
        .device = device,
    };
}

pub fn deinit(self: *Self) void {
    //c.vkDestroyBuffer(self.device.globalDevice, self.vertexBuffer, null);
    //c.vkFreeMemory(self.device.globalDevice, self.vertexBufferMemory, null);
    _ = self;
}
