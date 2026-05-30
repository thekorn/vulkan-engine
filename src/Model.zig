const std = @import("std");

const c = @import("c.zig").c;
const math = @import("math.zig");
const Device = @import("Device.zig");
const checkSuccess = @import("utils.zig").checkSuccess;
const ArrayList = std.ArrayList;

const Self = @This();
device: *Device,
vertexCount: u32,
vertexBuffer: c.VkBuffer = undefined,
vertexBufferMemory: c.VkDeviceMemory = undefined,

hasIndexBuffer: bool = false,
indexCount: u32 = 0,
indexBuffer: c.VkBuffer = undefined,
indexBufferMemory: c.VkDeviceMemory = undefined,

pub const Vertex = extern struct {
    position: math.Vec3 = .{ 0, 0, 0 },
    color: math.Vec3 = .{ 0, 0, 0 },

    pub fn getBindingDescriptions() [1]c.VkVertexInputBindingDescription {
        return [1]c.VkVertexInputBindingDescription{
            c.VkVertexInputBindingDescription{
                .binding = 0,
                .stride = @sizeOf(Vertex),
                .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX,
            },
        };
    }

    pub fn getAttributeDescriptions() [2]c.VkVertexInputAttributeDescription {
        return [2]c.VkVertexInputAttributeDescription{
            c.VkVertexInputAttributeDescription{
                .location = 0,
                .binding = 0,
                .format = c.VK_FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex, "position"),
            },
            c.VkVertexInputAttributeDescription{
                .location = 1,
                .binding = 0,
                .format = c.VK_FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex, "color"),
            },
        };
    }
};

/// Builder mirrors the upstream C++ tutorial's `LveModel::Builder`. It
/// bundles the vertex / index slices used to construct a `Model`.
/// Indices may be empty, in which case the model falls back to
/// non-indexed drawing via `vkCmdDraw`.
pub const Builder = struct {
    vertices: []const Vertex = &.{},
    indices: []const u32 = &.{},
};

pub fn init(device: *Device, builder: Builder) !Self {
    var model = Self{
        .device = device,
        .vertexCount = @intCast(builder.vertices.len),
    };
    try createVertexBuffers(&model, builder.vertices);
    errdefer {
        c.vkDestroyBuffer(device.globalDevice, model.vertexBuffer, null);
        c.vkFreeMemory(device.globalDevice, model.vertexBufferMemory, null);
    }
    try createIndexBuffers(&model, builder.indices);

    return model;
}

pub fn deinit(self: *Self) void {
    c.vkDestroyBuffer(self.device.globalDevice, self.vertexBuffer, null);
    c.vkFreeMemory(self.device.globalDevice, self.vertexBufferMemory, null);

    if (self.hasIndexBuffer) {
        c.vkDestroyBuffer(self.device.globalDevice, self.indexBuffer, null);
        c.vkFreeMemory(self.device.globalDevice, self.indexBufferMemory, null);
    }
}

fn createVertexBuffers(self: *Self, vertices: []const Vertex) !void {
    if (vertices.len < 3) return error.InvalidArgument;
    const buffer_size: u64 = @sizeOf(Vertex) * vertices.len;

    var stagingBuffer: c.VkBuffer = undefined;
    var stagingBufferMemory: c.VkDeviceMemory = undefined;
    try self.device.createBuffer(
        buffer_size,
        c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        &stagingBuffer,
        &stagingBufferMemory,
    );
    defer {
        c.vkDestroyBuffer(self.device.globalDevice, stagingBuffer, null);
        c.vkFreeMemory(self.device.globalDevice, stagingBufferMemory, null);
    }

    var data: [*]u8 = undefined;
    try checkSuccess(c.vkMapMemory(
        self.device.globalDevice,
        stagingBufferMemory,
        0,
        buffer_size,
        0,
        @ptrCast(&data),
    ));
    @memcpy(data[0..buffer_size], std.mem.sliceAsBytes(vertices));
    c.vkUnmapMemory(self.device.globalDevice, stagingBufferMemory);

    try self.device.createBuffer(
        buffer_size,
        c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        &self.vertexBuffer,
        &self.vertexBufferMemory,
    );
    errdefer {
        c.vkDestroyBuffer(self.device.globalDevice, self.vertexBuffer, null);
        c.vkFreeMemory(self.device.globalDevice, self.vertexBufferMemory, null);
    }

    try self.device.copyBuffer(stagingBuffer, self.vertexBuffer, buffer_size);
}

fn createIndexBuffers(self: *Self, indices: []const u32) !void {
    self.indexCount = @intCast(indices.len);
    self.hasIndexBuffer = self.indexCount > 0;
    if (!self.hasIndexBuffer) return;

    const buffer_size: u64 = @sizeOf(u32) * indices.len;

    var stagingBuffer: c.VkBuffer = undefined;
    var stagingBufferMemory: c.VkDeviceMemory = undefined;
    try self.device.createBuffer(
        buffer_size,
        c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        &stagingBuffer,
        &stagingBufferMemory,
    );
    defer {
        c.vkDestroyBuffer(self.device.globalDevice, stagingBuffer, null);
        c.vkFreeMemory(self.device.globalDevice, stagingBufferMemory, null);
    }

    var data: [*]u8 = undefined;
    try checkSuccess(c.vkMapMemory(
        self.device.globalDevice,
        stagingBufferMemory,
        0,
        buffer_size,
        0,
        @ptrCast(&data),
    ));
    @memcpy(data[0..buffer_size], std.mem.sliceAsBytes(indices));
    c.vkUnmapMemory(self.device.globalDevice, stagingBufferMemory);

    try self.device.createBuffer(
        buffer_size,
        c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        &self.indexBuffer,
        &self.indexBufferMemory,
    );
    errdefer {
        c.vkDestroyBuffer(self.device.globalDevice, self.indexBuffer, null);
        c.vkFreeMemory(self.device.globalDevice, self.indexBufferMemory, null);
    }

    try self.device.copyBuffer(stagingBuffer, self.indexBuffer, buffer_size);
}

pub fn draw(self: Self, commandBuffer: c.VkCommandBuffer) void {
    if (self.hasIndexBuffer) {
        c.vkCmdDrawIndexed(commandBuffer, self.indexCount, 1, 0, 0, 0);
    } else {
        c.vkCmdDraw(commandBuffer, self.vertexCount, 1, 0, 0);
    }
}

pub fn bind(self: Self, commandBuffer: c.VkCommandBuffer) void {
    var buffers: [1]c.VkBuffer = [1]c.VkBuffer{self.vertexBuffer};
    var offsets: [1]u64 = [1]u64{0};
    c.vkCmdBindVertexBuffers(commandBuffer, 0, 1, &buffers, &offsets);

    if (self.hasIndexBuffer) {
        c.vkCmdBindIndexBuffer(commandBuffer, self.indexBuffer, 0, c.VK_INDEX_TYPE_UINT32);
    }
}

test "Vertex has expected size and position field" {
    const position_type = @TypeOf(@field(@as(Vertex, undefined), "position"));
    const color_type = @TypeOf(@field(@as(Vertex, undefined), "color"));

    const position_end = @offsetOf(Vertex, "position") + @sizeOf(position_type);
    const color_end = @offsetOf(Vertex, "color") + @sizeOf(color_type);
    const data_end = @max(position_end, color_end);
    const expected_size = std.mem.alignForward(usize, data_end, @alignOf(Vertex));

    // Derive the expected size from the actual field layout and struct alignment
    // rather than hard-coding a target/ABI-specific total size for vector fields.
    try std.testing.expectEqual(expected_size, @sizeOf(Vertex));

    const v = Vertex{ .position = .{ 1.0, 2.0, 3.0 }, .color = .{ 1.0, 0.0, 0.0 } };
    try std.testing.expectEqual(@as(f32, 1.0), v.position[0]);
    try std.testing.expectEqual(@as(f32, 2.0), v.position[1]);
    try std.testing.expectEqual(@as(f32, 3.0), v.position[2]);
    try std.testing.expectEqual(@as(f32, 1.0), v.color[0]);
    try std.testing.expectEqual(@as(f32, 0.0), v.color[1]);
    try std.testing.expectEqual(@as(f32, 0.0), v.color[2]);
}

test "Vertex.getBindingDescriptions returns a single binding for binding 0" {
    const bindings = Vertex.getBindingDescriptions();

    try std.testing.expectEqual(@as(usize, 1), bindings.len);
    try std.testing.expectEqual(@as(u32, 0), bindings[0].binding);
    try std.testing.expectEqual(@as(u32, @sizeOf(Vertex)), bindings[0].stride);
    try std.testing.expectEqual(
        @as(c_uint, c.VK_VERTEX_INPUT_RATE_VERTEX),
        bindings[0].inputRate,
    );
}

test "Vertex.getAttributeDescriptions returns R32G32B32_SFLOAT position and color attributes" {
    const attrs = Vertex.getAttributeDescriptions();

    try std.testing.expectEqual(@as(usize, 2), attrs.len);
    try std.testing.expectEqual(@as(u32, 0), attrs[0].location);
    try std.testing.expectEqual(@as(u32, 0), attrs[0].binding);
    try std.testing.expectEqual(
        @as(c_uint, c.VK_FORMAT_R32G32B32_SFLOAT),
        attrs[0].format,
    );
    try std.testing.expectEqual(@as(u32, @offsetOf(Vertex, "position")), attrs[0].offset);
}

test "Model has expected fields and types" {
    const fields = @typeInfo(Self).@"struct".fields;

    try std.testing.expectEqual(@as(usize, 8), fields.len);
    try std.testing.expectEqualStrings("device", fields[0].name);
    try std.testing.expectEqual(*Device, fields[0].type);
    try std.testing.expectEqualStrings("vertexCount", fields[1].name);
    try std.testing.expectEqual(u32, fields[1].type);
    try std.testing.expectEqualStrings("vertexBuffer", fields[2].name);
    try std.testing.expectEqual(c.VkBuffer, fields[2].type);
    try std.testing.expectEqualStrings("vertexBufferMemory", fields[3].name);
    try std.testing.expectEqual(c.VkDeviceMemory, fields[3].type);
    try std.testing.expectEqualStrings("hasIndexBuffer", fields[4].name);
    try std.testing.expectEqual(bool, fields[4].type);
    try std.testing.expectEqualStrings("indexCount", fields[5].name);
    try std.testing.expectEqual(u32, fields[5].type);
    try std.testing.expectEqualStrings("indexBuffer", fields[6].name);
    try std.testing.expectEqual(c.VkBuffer, fields[6].type);
    try std.testing.expectEqualStrings("indexBufferMemory", fields[7].name);
    try std.testing.expectEqual(c.VkDeviceMemory, fields[7].type);
}

test "createVertexBuffers rejects fewer than 3 vertices" {
    var device: Device = undefined;
    var model = Self{
        .device = &device,
        .vertexCount = 0,
    };

    const empty: []const Vertex = &.{};
    try std.testing.expectError(error.InvalidArgument, createVertexBuffers(&model, empty));

    const one = [_]Vertex{
        .{ .position = .{ 0.0, 0.0, 0.0 }, .color = .{ 1.0, 0.0, 0.0 } },
    };
    try std.testing.expectError(error.InvalidArgument, createVertexBuffers(&model, one[0..]));

    const two = [_]Vertex{
        .{ .position = .{ 0.0, 0.0, 0.0 }, .color = .{ 1.0, 0.0, 0.0 } },
        .{ .position = .{ 1.0, 0.0, 0.0 }, .color = .{ 0.0, 1.0, 0.0 } },
    };
    try std.testing.expectError(error.InvalidArgument, createVertexBuffers(&model, two[0..]));
}

test "Vertex.getBindingDescriptions stride equals @sizeOf(Vertex)" {
    const bindings = Vertex.getBindingDescriptions();
    try std.testing.expectEqual(@sizeOf(Vertex), bindings[0].stride);
}

test "Vertex.getAttributeDescriptions places color at @offsetOf(Vertex, \"color\")" {
    const attrs = Vertex.getAttributeDescriptions();
    try std.testing.expectEqual(@as(u32, 1), attrs[1].location);
    try std.testing.expectEqual(@as(u32, 0), attrs[1].binding);
    try std.testing.expectEqual(
        @as(c_uint, c.VK_FORMAT_R32G32B32_SFLOAT),
        attrs[1].format,
    );
    try std.testing.expectEqual(@as(u32, @offsetOf(Vertex, "color")), attrs[1].offset);
}

test "Vertex.getAttributeDescriptions offsets are distinct" {
    const attrs = Vertex.getAttributeDescriptions();
    try std.testing.expect(attrs[0].offset != attrs[1].offset);
}

test "Model struct can be constructed with default undefined buffer fields" {
    var device: Device = undefined;
    const model = Self{
        .device = &device,
        .vertexCount = 42,
    };
    try std.testing.expectEqual(@as(u32, 42), model.vertexCount);
    try std.testing.expectEqual(&device, model.device);
    try std.testing.expectEqual(false, model.hasIndexBuffer);
    try std.testing.expectEqual(@as(u32, 0), model.indexCount);
}

test "Builder defaults to empty vertex and index slices" {
    const builder: Builder = .{};
    try std.testing.expectEqual(@as(usize, 0), builder.vertices.len);
    try std.testing.expectEqual(@as(usize, 0), builder.indices.len);
}
