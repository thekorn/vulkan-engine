const std = @import("std");

const c = @import("c.zig").c;
//const cglm = @import("c.zig").cglm;
const Device = @import("Device.zig");
const checkSuccess = @import("utils.zig").checkSuccess;
const ArrayList = std.ArrayList;

const Self = @This();
device: *Device,
vertexCount: u32,
vertexBuffer: c.VkBuffer = undefined,
vertexBufferMemory: c.VkDeviceMemory = undefined,

pub const Vertex = struct {
    position: @Vector(2, f32),

    pub fn getBindingDescriptions() [1]c.VkVertexInputBindingDescription {
        return [1]c.VkVertexInputBindingDescription{
            c.VkVertexInputBindingDescription{
                .binding = 0,
                .stride = @sizeOf(Vertex),
                .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX,
            },
        };
    }

    pub fn getAttributeDescriptions() [1]c.VkVertexInputAttributeDescription {
        return [1]c.VkVertexInputAttributeDescription{
            c.VkVertexInputAttributeDescription{
                .location = 0,
                .binding = 0,
                .format = c.VK_FORMAT_R32G32_SFLOAT,
                .offset = 0, //@offsetOf(Vertex, "position"),
            },
        };
    }
};

pub fn init(device: *Device, vertices: []const Vertex) !Self {
    var model = Self{
        .device = device,
        .vertexCount = @intCast(vertices.len),
    };
    try createVertexBuffers(&model, vertices);

    return model;
}

pub fn deinit(self: *Self) void {
    c.vkDestroyBuffer(self.device.globalDevice, self.vertexBuffer, null);
    c.vkFreeMemory(self.device.globalDevice, self.vertexBufferMemory, null);
}

fn createVertexBuffers(self: *Self, vertices: []const Vertex) !void {
    if (vertices.len < 3) return error.InvalidArgument;
    const vertex_buffer_size = @sizeOf(Vertex) * vertices.len;
    try self.device.createBuffer(
        vertex_buffer_size,
        c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        &self.vertexBuffer,
        &self.vertexBufferMemory,
    );

    var data: [*]u8 = undefined;
    try checkSuccess(c.vkMapMemory(
        self.device.globalDevice,
        self.vertexBufferMemory,
        0,
        vertex_buffer_size,
        0,
        @ptrCast(&data),
    ));
    @memcpy(data[0..vertex_buffer_size], std.mem.sliceAsBytes(vertices));
    c.vkUnmapMemory(self.device.globalDevice, self.vertexBufferMemory);
}

pub fn draw(self: Self, commandBuffer: c.VkCommandBuffer) void {
    c.vkCmdDraw(commandBuffer, self.vertexCount, 1, 0, 0);
}

pub fn bind(self: Self, commandBuffer: c.VkCommandBuffer) void {
    var buffers: [1]c.VkBuffer = [1]c.VkBuffer{self.vertexBuffer};
    var offsets: [1]u64 = [1]u64{0};
    c.vkCmdBindVertexBuffers(commandBuffer, 0, 1, &buffers, &offsets);
}
