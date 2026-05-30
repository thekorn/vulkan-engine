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
    /// [tinyobjloader-c](https://github.com/syoyo/tinyobjloader-c)
    /// (vendored via `build.zig.zon`); the parser triangulates polygonal
    /// faces, and this function deduplicates exactly-matching vertices
    /// (same position / color / normal / uv) using a hash map — mirroring
    /// the `std::unordered_map<Vertex, uint32_t>` loop in `lve_model.cpp`
    /// from the upstream C++ tutorial.
    pub fn loadModel(
        self: *Builder,
        alloc: std.mem.Allocator,
        bytes: []const u8,
    ) !void {
        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();

        // tinyobjloader-c does all I/O through a user callback so it
        // can transparently support virtual file systems. We feed it
        // the in-memory OBJ bytes directly and ignore `.mtl` requests
        // since this engine doesn't consume materials.
        var ctx: MemReaderCtx = .{ .bytes = bytes };

        var attrib: c.tinyobj_attrib_t = undefined;
        c.tinyobj_attrib_init(&attrib);
        defer c.tinyobj_attrib_free(&attrib);

        var shapes: [*c]c.tinyobj_shape_t = null;
        var num_shapes: usize = 0;
        var materials: [*c]c.tinyobj_material_t = null;
        var num_materials: usize = 0;

        const rc = c.tinyobj_parse_obj(
            &attrib,
            &shapes,
            &num_shapes,
            &materials,
            &num_materials,
            // The library passes this string back into the reader
            // callback as the `filename` argument; we ignore it.
            "<memory>",
            memReaderCallback,
            &ctx,
            c.TINYOBJ_FLAG_TRIANGULATE,
        );
        defer c.tinyobj_shapes_free(shapes, num_shapes);
        defer c.tinyobj_materials_free(materials, num_materials);

        if (rc != c.TINYOBJ_SUCCESS) {
            std.log.scoped(.model).err("tinyobjloader-c: parse failed ({d})", .{rc});
            return error.InvalidObj;
        }

        // Per-corner dedup: walk every triangle corner across every
        // shape, build the matching `Vertex`, and look it up in a hash
        // map keyed by exact field equality. New vertices get the next
        // available index.
        var unique: std.HashMapUnmanaged(Vertex, u32, VertexHashCtx, 80) = .empty;
        defer unique.deinit(alloc);

        const num_corners = attrib.num_faces;
        try self.indices.ensureTotalCapacity(alloc, num_corners);

        var corner: usize = 0;
        while (corner < num_corners) : (corner += 1) {
            const idx = attrib.faces[corner];

            var v: Vertex = .{};
            if (idx.v_idx >= 0) {
                const base: usize = @intCast(@as(c_int, idx.v_idx) * 3);
                v.position = .{
                    attrib.vertices[base + 0],
                    attrib.vertices[base + 1],
                    attrib.vertices[base + 2],
                };
                // tinyobjloader-c doesn't parse the optional
                // `v x y z r g b` color extension, so default to white
                // (matching the C++ tinyobjloader behavior when no
                // color is provided).
                v.color = .{ 1.0, 1.0, 1.0 };
            }
            if (idx.vn_idx >= 0) {
                const base: usize = @intCast(@as(c_int, idx.vn_idx) * 3);
                v.normal = .{
                    attrib.normals[base + 0],
                    attrib.normals[base + 1],
                    attrib.normals[base + 2],
                };
            }
            if (idx.vt_idx >= 0) {
                const base: usize = @intCast(@as(c_int, idx.vt_idx) * 2);
                v.uv = .{
                    attrib.texcoords[base + 0],
                    attrib.texcoords[base + 1],
                };
            }

            const gop = try unique.getOrPut(alloc, v);
            if (!gop.found_existing) {
                const new_id: u32 = @intCast(self.vertices.items.len);
                gop.value_ptr.* = new_id;
                try self.vertices.append(alloc, v);
            }
            self.indices.appendAssumeCapacity(gop.value_ptr.*);
        }
    }
};

/// Context carried through the tinyobjloader-c file-reader callback.
/// The library never frees `*buf`, so we point it straight at the
/// caller-provided OBJ byte slice and let Zig keep ownership.
const MemReaderCtx = struct {
    bytes: []const u8,
};

fn memReaderCallback(
    ctx_opaque: ?*anyopaque,
    filename: [*c]const u8,
    is_mtl: c_int,
    obj_filename: [*c]const u8,
    out_buf: [*c][*c]u8,
    out_len: [*c]usize,
) callconv(.c) void {
    _ = filename;
    _ = obj_filename;

    // tinyobjloader-c calls back into us twice: once for the OBJ
    // (is_mtl=0) and, if the file references `mtllib`, once more for
    // the .mtl (is_mtl=1). This engine ignores materials, so signal
    // "not found" for any .mtl request and the library will continue
    // without materials.
    if (is_mtl != 0) {
        out_buf.* = null;
        out_len.* = 0;
        return;
    }

    const ctx: *MemReaderCtx = @ptrCast(@alignCast(ctx_opaque.?));
    out_buf.* = @constCast(@ptrCast(ctx.bytes.ptr));
    out_len.* = ctx.bytes.len;
}

/// Hash-map context for byte-exact `Vertex` equality. Safe because
/// `Vertex` is an `extern struct` of `@Vector`-backed `f32`
/// components with no padding holes (its size is a multiple of
/// `@alignOf(Vertex)`), so two semantically-equal vertices have
/// identical byte representations.
const VertexHashCtx = struct {
    pub fn hash(_: VertexHashCtx, v: Vertex) u64 {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&v));
    }
    pub fn eql(_: VertexHashCtx, a: Vertex, b: Vertex) bool {
        return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
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

test "Builder.loadModel ignores the `v x y z r g b` color extension (defaults to white)" {
    // tinyobjloader-c does not parse the non-standard per-vertex color
    // extension `v x y z r g b`; the trailing `r g b` floats are
    // silently dropped and every vertex's color defaults to white.
    // This matches plain OBJ semantics (colors normally come from
    // materials, not from `v` lines).
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

    for (builder.vertices.items) |v| {
        try std.testing.expectEqual(@as(f32, 1.0), v.color[0]);
        try std.testing.expectEqual(@as(f32, 1.0), v.color[1]);
        try std.testing.expectEqual(@as(f32, 1.0), v.color[2]);
    }
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
