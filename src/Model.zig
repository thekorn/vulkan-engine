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
    normal: math.Vec3 = .{ 0, 0, 0 },
    uv: math.Vec2 = .{ 0, 0 },

    pub fn getBindingDescriptions() [1]c.VkVertexInputBindingDescription {
        return [1]c.VkVertexInputBindingDescription{
            c.VkVertexInputBindingDescription{
                .binding = 0,
                .stride = @sizeOf(Vertex),
                .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX,
            },
        };
    }

    pub fn getAttributeDescriptions() [4]c.VkVertexInputAttributeDescription {
        return [4]c.VkVertexInputAttributeDescription{
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
            c.VkVertexInputAttributeDescription{
                .location = 2,
                .binding = 0,
                .format = c.VK_FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex, "normal"),
            },
            c.VkVertexInputAttributeDescription{
                .location = 3,
                .binding = 0,
                .format = c.VK_FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(Vertex, "uv"),
            },
        };
    }
};

/// Builder mirrors the upstream C++ tutorial's `LveModel::Builder`. It
/// bundles the vertex / index arrays used to construct a `Model`.
/// Indices may be empty, in which case the model falls back to
/// non-indexed drawing via `vkCmdDraw`.
///
/// The builder owns its `vertices` / `indices` storage; call
/// `deinit(alloc)` once a `Model` has been constructed from it.
pub const Builder = struct {
    vertices: ArrayList(Vertex) = .empty,
    indices: ArrayList(u32) = .empty,

    pub fn deinit(self: *Builder, alloc: std.mem.Allocator) void {
        self.vertices.deinit(alloc);
        self.indices.deinit(alloc);
    }

    /// Parse a Wavefront OBJ file (`bytes`) into this builder, replacing
    /// any previously stored vertices/indices. Delegates to
    /// tinyobjloader via the small C-ABI wrapper in
    /// `src/tinyobj_wrapper.cpp`; tinyobjloader triangulates polygonal
    /// faces and the wrapper performs per-vertex deduplication, exactly
    /// as in the upstream C++ tutorial.
    pub fn loadModel(
        self: *Builder,
        alloc: std.mem.Allocator,
        bytes: []const u8,
    ) !void {
        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();

        var vertices_ptr: [*c]c.tinyobj_wrapper_vertex = null;
        var vertices_count: usize = 0;
        var indices_ptr: [*c]u32 = null;
        var indices_count: usize = 0;
        var err_msg: [*c]u8 = null;

        const ok = c.tinyobj_load_bytes(
            bytes.ptr,
            bytes.len,
            &vertices_ptr,
            &vertices_count,
            &indices_ptr,
            &indices_count,
            &err_msg,
        );
        defer {
            c.tinyobj_free(vertices_ptr);
            c.tinyobj_free(indices_ptr);
            c.tinyobj_free(err_msg);
        }

        if (ok == 0) {
            if (err_msg != null) {
                std.log.scoped(.model).err("tinyobjloader: {s}", .{err_msg});
            }
            return error.InvalidObj;
        }

        try self.vertices.ensureTotalCapacityPrecise(alloc, vertices_count);
        if (vertices_count > 0) for (vertices_ptr[0..vertices_count]) |wv| {
            self.vertices.appendAssumeCapacity(.{
                .position = .{ wv.position[0], wv.position[1], wv.position[2] },
                .color = .{ wv.color[0], wv.color[1], wv.color[2] },
                .normal = .{ wv.normal[0], wv.normal[1], wv.normal[2] },
                .uv = .{ wv.uv[0], wv.uv[1] },
            });
        };

        if (indices_count > 0) {
            try self.indices.appendSlice(alloc, indices_ptr[0..indices_count]);
        }
    }
};

pub fn init(device: *Device, builder: Builder) !Self {
    var model = Self{
        .device = device,
        .vertexCount = @intCast(builder.vertices.items.len),
    };
    try createVertexBuffers(&model, builder.vertices.items);
    errdefer {
        c.vkDestroyBuffer(device.globalDevice, model.vertexBuffer, null);
        c.vkFreeMemory(device.globalDevice, model.vertexBufferMemory, null);
    }
    try createIndexBuffers(&model, builder.indices.items);

    return model;
}

/// Build a `Model` from an in-memory OBJ file (typically obtained via
/// `@embedFile`). Mirrors `LveModel::createModelFromFile` in the C++
/// tutorial, which takes a filesystem path and uses tinyobjloader.
pub fn createModelFromFile(
    device: *Device,
    alloc: std.mem.Allocator,
    obj_bytes: []const u8,
) !Self {
    var builder: Builder = .{};
    defer builder.deinit(alloc);
    try builder.loadModel(alloc, obj_bytes);
    return Self.init(device, builder);
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

test "Vertex has expected size derived from field layout" {
    const position_type = @TypeOf(@field(@as(Vertex, undefined), "position"));
    const color_type = @TypeOf(@field(@as(Vertex, undefined), "color"));
    const normal_type = @TypeOf(@field(@as(Vertex, undefined), "normal"));
    const uv_type = @TypeOf(@field(@as(Vertex, undefined), "uv"));

    const ends = [_]usize{
        @offsetOf(Vertex, "position") + @sizeOf(position_type),
        @offsetOf(Vertex, "color") + @sizeOf(color_type),
        @offsetOf(Vertex, "normal") + @sizeOf(normal_type),
        @offsetOf(Vertex, "uv") + @sizeOf(uv_type),
    };
    var data_end: usize = 0;
    for (ends) |e| if (e > data_end) {
        data_end = e;
    };
    const expected_size = std.mem.alignForward(usize, data_end, @alignOf(Vertex));

    // Derive the expected size from the actual field layout and struct
    // alignment rather than hard-coding a target/ABI-specific total
    // size for vector fields.
    try std.testing.expectEqual(expected_size, @sizeOf(Vertex));

    const v = Vertex{
        .position = .{ 1.0, 2.0, 3.0 },
        .color = .{ 1.0, 0.0, 0.0 },
        .normal = .{ 0.0, 1.0, 0.0 },
        .uv = .{ 0.5, 0.25 },
    };
    try std.testing.expectEqual(@as(f32, 1.0), v.position[0]);
    try std.testing.expectEqual(@as(f32, 2.0), v.position[1]);
    try std.testing.expectEqual(@as(f32, 3.0), v.position[2]);
    try std.testing.expectEqual(@as(f32, 1.0), v.color[0]);
    try std.testing.expectEqual(@as(f32, 0.0), v.normal[0]);
    try std.testing.expectEqual(@as(f32, 1.0), v.normal[1]);
    try std.testing.expectEqual(@as(f32, 0.5), v.uv[0]);
    try std.testing.expectEqual(@as(f32, 0.25), v.uv[1]);
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

test "Vertex.getAttributeDescriptions has position, color, normal, uv" {
    const attrs = Vertex.getAttributeDescriptions();

    try std.testing.expectEqual(@as(usize, 4), attrs.len);

    // position @ location 0
    try std.testing.expectEqual(@as(u32, 0), attrs[0].location);
    try std.testing.expectEqual(@as(u32, 0), attrs[0].binding);
    try std.testing.expectEqual(
        @as(c_uint, c.VK_FORMAT_R32G32B32_SFLOAT),
        attrs[0].format,
    );
    try std.testing.expectEqual(@as(u32, @offsetOf(Vertex, "position")), attrs[0].offset);

    // color @ location 1
    try std.testing.expectEqual(@as(u32, 1), attrs[1].location);
    try std.testing.expectEqual(@as(u32, 0), attrs[1].binding);
    try std.testing.expectEqual(
        @as(c_uint, c.VK_FORMAT_R32G32B32_SFLOAT),
        attrs[1].format,
    );
    try std.testing.expectEqual(@as(u32, @offsetOf(Vertex, "color")), attrs[1].offset);

    // normal @ location 2
    try std.testing.expectEqual(@as(u32, 2), attrs[2].location);
    try std.testing.expectEqual(@as(u32, 0), attrs[2].binding);
    try std.testing.expectEqual(
        @as(c_uint, c.VK_FORMAT_R32G32B32_SFLOAT),
        attrs[2].format,
    );
    try std.testing.expectEqual(@as(u32, @offsetOf(Vertex, "normal")), attrs[2].offset);

    // uv @ location 3 (2-component)
    try std.testing.expectEqual(@as(u32, 3), attrs[3].location);
    try std.testing.expectEqual(@as(u32, 0), attrs[3].binding);
    try std.testing.expectEqual(
        @as(c_uint, c.VK_FORMAT_R32G32_SFLOAT),
        attrs[3].format,
    );
    try std.testing.expectEqual(@as(u32, @offsetOf(Vertex, "uv")), attrs[3].offset);
}

test "Vertex.getAttributeDescriptions offsets are all distinct" {
    const attrs = Vertex.getAttributeDescriptions();
    inline for (0..attrs.len) |i| {
        inline for ((i + 1)..attrs.len) |j| {
            try std.testing.expect(attrs[i].offset != attrs[j].offset);
        }
    }
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

test "Builder defaults to empty vertex and index lists" {
    const builder: Builder = .{};
    try std.testing.expectEqual(@as(usize, 0), builder.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 0), builder.indices.items.len);
}

test "Builder.loadModel parses a minimal triangle" {
    const alloc = std.testing.allocator;
    const obj =
        \\# minimal triangle
        \\v 0.0 0.0 0.0
        \\v 1.0 0.0 0.0
        \\v 0.0 1.0 0.0
        \\f 1 2 3
        \\
    ;
    var builder: Builder = .{};
    defer builder.deinit(alloc);
    try builder.loadModel(alloc, obj);

    try std.testing.expectEqual(@as(usize, 3), builder.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 3), builder.indices.items.len);
    try std.testing.expectEqual(@as(u32, 0), builder.indices.items[0]);
    try std.testing.expectEqual(@as(u32, 1), builder.indices.items[1]);
    try std.testing.expectEqual(@as(u32, 2), builder.indices.items[2]);

    try std.testing.expectEqual(@as(f32, 0.0), builder.vertices.items[0].position[0]);
    try std.testing.expectEqual(@as(f32, 1.0), builder.vertices.items[1].position[0]);
    try std.testing.expectEqual(@as(f32, 1.0), builder.vertices.items[2].position[1]);
    // Default color when `v` has no `r g b` is white.
    try std.testing.expectEqual(@as(f32, 1.0), builder.vertices.items[0].color[0]);
    try std.testing.expectEqual(@as(f32, 1.0), builder.vertices.items[0].color[1]);
    try std.testing.expectEqual(@as(f32, 1.0), builder.vertices.items[0].color[2]);
}

test "Builder.loadModel triangulates a quad into two triangles" {
    const alloc = std.testing.allocator;
    const obj =
        \\v 0 0 0
        \\v 1 0 0
        \\v 1 1 0
        \\v 0 1 0
        \\f 1 2 3 4
        \\
    ;
    var builder: Builder = .{};
    defer builder.deinit(alloc);
    try builder.loadModel(alloc, obj);

    try std.testing.expectEqual(@as(usize, 4), builder.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 6), builder.indices.items.len);
    // Fan from vertex 0: triangles (0,1,2) and (0,2,3).
    try std.testing.expectEqual(@as(u32, 0), builder.indices.items[0]);
    try std.testing.expectEqual(@as(u32, 1), builder.indices.items[1]);
    try std.testing.expectEqual(@as(u32, 2), builder.indices.items[2]);
    try std.testing.expectEqual(@as(u32, 0), builder.indices.items[3]);
    try std.testing.expectEqual(@as(u32, 2), builder.indices.items[4]);
    try std.testing.expectEqual(@as(u32, 3), builder.indices.items[5]);
}

test "Builder.loadModel deduplicates identical vertices across faces" {
    const alloc = std.testing.allocator;
    // Two triangles that share an edge — 4 distinct positions, 6 indices.
    const obj =
        \\v 0 0 0
        \\v 1 0 0
        \\v 0 1 0
        \\v 1 1 0
        \\f 1 2 3
        \\f 2 4 3
        \\
    ;
    var builder: Builder = .{};
    defer builder.deinit(alloc);
    try builder.loadModel(alloc, obj);

    try std.testing.expectEqual(@as(usize, 4), builder.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 6), builder.indices.items.len);
}

test "Builder.loadModel handles v/vt/vn face syntax and normals/texcoords" {
    const alloc = std.testing.allocator;
    const obj =
        \\v 0 0 0
        \\v 1 0 0
        \\v 0 1 0
        \\vn 0 0 1
        \\vt 0 0
        \\vt 1 0
        \\vt 0 1
        \\f 1/1/1 2/2/1 3/3/1
        \\
    ;
    var builder: Builder = .{};
    defer builder.deinit(alloc);
    try builder.loadModel(alloc, obj);

    try std.testing.expectEqual(@as(usize, 3), builder.vertices.items.len);
    for (builder.vertices.items) |v| {
        try std.testing.expectEqual(@as(f32, 1.0), v.normal[2]);
    }
    try std.testing.expectEqual(@as(f32, 0.0), builder.vertices.items[0].uv[0]);
    try std.testing.expectEqual(@as(f32, 1.0), builder.vertices.items[1].uv[0]);
    try std.testing.expectEqual(@as(f32, 1.0), builder.vertices.items[2].uv[1]);
}

test "Builder.loadModel handles v//vn (no texcoords) face syntax" {
    const alloc = std.testing.allocator;
    const obj =
        \\v 0 0 0
        \\v 1 0 0
        \\v 0 1 0
        \\vn 0 0 1
        \\f 1//1 2//1 3//1
    ;
    var builder: Builder = .{};
    defer builder.deinit(alloc);
    try builder.loadModel(alloc, obj);

    try std.testing.expectEqual(@as(usize, 3), builder.vertices.items.len);
    for (builder.vertices.items) |v| {
        try std.testing.expectEqual(@as(f32, 1.0), v.normal[2]);
        try std.testing.expectEqual(@as(f32, 0.0), v.uv[0]);
        try std.testing.expectEqual(@as(f32, 0.0), v.uv[1]);
    }
}

test "Builder.loadModel reads optional per-vertex color from `v x y z r g b`" {
    const alloc = std.testing.allocator;
    const obj =
        \\v 0 0 0 0.5 0.25 0.75
        \\v 1 0 0 1.0 0.0 0.0
        \\v 0 1 0 0.0 1.0 0.0
        \\f 1 2 3
    ;
    var builder: Builder = .{};
    defer builder.deinit(alloc);
    try builder.loadModel(alloc, obj);

    try std.testing.expectEqual(@as(f32, 0.5), builder.vertices.items[0].color[0]);
    try std.testing.expectEqual(@as(f32, 0.25), builder.vertices.items[0].color[1]);
    try std.testing.expectEqual(@as(f32, 0.75), builder.vertices.items[0].color[2]);
    try std.testing.expectEqual(@as(f32, 1.0), builder.vertices.items[1].color[0]);
    try std.testing.expectEqual(@as(f32, 1.0), builder.vertices.items[2].color[1]);
}

test "Builder.loadModel ignores comments, blank lines, and unsupported directives" {
    const alloc = std.testing.allocator;
    const obj =
        \\# a comment
        \\mtllib something.mtl
        \\o my_object
        \\g group
        \\s 1
        \\
        \\v 0 0 0
        \\v 1 0 0
        \\v 0 1 0
        \\usemtl foo
        \\f 1 2 3
    ;
    var builder: Builder = .{};
    defer builder.deinit(alloc);
    try builder.loadModel(alloc, obj);

    try std.testing.expectEqual(@as(usize, 3), builder.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 3), builder.indices.items.len);
}

test "Builder.loadModel parses the embedded smooth_vase.obj" {
    const alloc = std.testing.allocator;
    const obj = @embedFile("smooth_vase.obj");
    var builder: Builder = .{};
    defer builder.deinit(alloc);
    try builder.loadModel(alloc, obj);

    // Sanity: a real model has many vertices/indices and the indices
    // come in triangles.
    try std.testing.expect(builder.vertices.items.len > 100);
    try std.testing.expect(builder.indices.items.len > 100);
    try std.testing.expectEqual(@as(usize, 0), builder.indices.items.len % 3);
    // Every index must be in range.
    for (builder.indices.items) |idx| {
        try std.testing.expect(@as(usize, idx) < builder.vertices.items.len);
    }
}
