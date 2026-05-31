const std = @import("std");

const c = @import("c.zig").c;
const math = @import("math.zig");
const Buffer = @import("Buffer.zig");
const Device = @import("Device.zig");
const ArrayList = std.ArrayList;

const Self = @This();
device: *Device,
vertexCount: u32,
// `vertexBuffer` and `indexBuffer` are owned `Buffer` wrappers so that
// the underlying `VkBuffer` + `VkDeviceMemory` (and any active mapping)
// are released together when the model is destroyed. Mirrors the
// `std::unique_ptr<LveBuffer>` fields used in the upstream C++
// tutorial.
vertexBuffer: Buffer,

hasIndexBuffer: bool = false,
indexCount: u32 = 0,
indexBuffer: ?Buffer = null,

pub const Vertex = extern struct {
    position: math.Vec3 = .{ 0, 0, 0 },
    color: math.Vec3 = .{ 0, 0, 0 },
    normal: math.Vec3 = .{ 0, 0, 0 },
    uv: math.Vec2 = .{ 0, 0 },
    /// Object-space tangent for normal mapping: `xyz` is the tangent
    /// direction along +U, `w` carries the bitangent handedness sign
    /// (+1 / -1) so the fragment shader can reconstruct the bitangent
    /// as `cross(N, T) * tangent.w`. Computed by
    /// `Builder.computeTangents` after the OBJ load + dedup pass.
    tangent: math.Vec4 = .{ 0, 0, 0, 0 },

    pub fn getBindingDescriptions() [1]c.VkVertexInputBindingDescription {
        return [1]c.VkVertexInputBindingDescription{
            c.VkVertexInputBindingDescription{
                .binding = 0,
                .stride = @sizeOf(Vertex),
                .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX,
            },
        };
    }

    pub fn getAttributeDescriptions() [5]c.VkVertexInputAttributeDescription {
        return [5]c.VkVertexInputAttributeDescription{
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
            c.VkVertexInputAttributeDescription{
                .location = 4,
                .binding = 0,
                .format = c.VK_FORMAT_R32G32B32A32_SFLOAT,
                .offset = @offsetOf(Vertex, "tangent"),
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
    /// `src/wrapper/tinyobj/tinyobj_wrapper.cpp`; tinyobjloader triangulates polygonal
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

        try self.computeTangents(alloc);
    }

    /// Compute per-vertex tangents (with handedness sign) from the
    /// already-populated `vertices` + `indices` arrays. Implements the
    /// standard "Lengyel" algorithm: per-triangle tangent / bitangent
    /// from `(edge1, edge2, dUV1, dUV2)`, accumulated per vertex,
    /// then Gram-Schmidt-orthogonalized against the vertex normal.
    /// The handedness sign in `tangent.w` lets the fragment shader
    /// reconstruct the bitangent as `cross(N, T) * tangent.w`.
    ///
    /// Triangles with a near-zero UV determinant (e.g. a mesh whose
    /// OBJ has no `vt` directives — tinyobjloader writes
    /// `uv = (0, 0)` for every vertex in that case) contribute
    /// nothing; vertices not reached by a well-conditioned triangle
    /// fall back to an arbitrary unit vector perpendicular to the
    /// normal so the TBN matrix in the shader stays valid even when
    /// the object is later rendered with the flat-normal fallback.
    fn computeTangents(self: *Builder, alloc: std.mem.Allocator) !void {
        const n = self.vertices.items.len;
        if (n == 0) return;

        const accum_t = try alloc.alloc(math.Vec3, n);
        defer alloc.free(accum_t);
        const accum_b = try alloc.alloc(math.Vec3, n);
        defer alloc.free(accum_b);
        @memset(accum_t, math.Vec3{ 0, 0, 0 });
        @memset(accum_b, math.Vec3{ 0, 0, 0 });

        // Walk the index buffer one triangle at a time. The vertex
        // indices are named `idx0` / `idx1` / `idx2` (rather than the
        // mathematical `i0` / `i1` / `i2`) because Zig 0.16 made
        // `i0`, `i1`, ... primitive integer type names.
        var tri: usize = 0;
        while (tri + 3 <= self.indices.items.len) : (tri += 3) {
            const idx0: usize = self.indices.items[tri];
            const idx1: usize = self.indices.items[tri + 1];
            const idx2: usize = self.indices.items[tri + 2];
            const v0 = self.vertices.items[idx0];
            const v1 = self.vertices.items[idx1];
            const v2 = self.vertices.items[idx2];

            const e1 = v1.position - v0.position;
            const e2 = v2.position - v0.position;
            const du1 = v1.uv - v0.uv;
            const du2 = v2.uv - v0.uv;

            const det = du1[0] * du2[1] - du2[0] * du1[1];
            if (@abs(det) < 1e-8) continue;
            const r: f32 = 1.0 / det;

            const t: math.Vec3 = .{
                (e1[0] * du2[1] - e2[0] * du1[1]) * r,
                (e1[1] * du2[1] - e2[1] * du1[1]) * r,
                (e1[2] * du2[1] - e2[2] * du1[1]) * r,
            };
            const b: math.Vec3 = .{
                (e2[0] * du1[0] - e1[0] * du2[0]) * r,
                (e2[1] * du1[0] - e1[1] * du2[0]) * r,
                (e2[2] * du1[0] - e1[2] * du2[0]) * r,
            };

            accum_t[idx0] += t;
            accum_t[idx1] += t;
            accum_t[idx2] += t;
            accum_b[idx0] += b;
            accum_b[idx1] += b;
            accum_b[idx2] += b;
        }

        for (self.vertices.items, 0..) |*v, idx| {
            const n_vec = v.normal;
            var t_vec = accum_t[idx];

            // Gram-Schmidt: project T onto the tangent plane defined
            // by N. Without this, non-orthogonal contributions across
            // shared edges drift the tangent away from the surface.
            const dot_nt = math.dot3(n_vec, t_vec);
            const n_scaled: math.Vec3 = n_vec * @as(math.Vec3, @splat(dot_nt));
            t_vec -= n_scaled;

            const tlen = math.length3(t_vec);
            if (tlen < 1e-6) {
                // Fallback: any vector perpendicular to N. Used by
                // vertices that weren't reached by a well-conditioned
                // triangle (e.g. the vase meshes whose OBJ has no
                // texcoords, so every triangle has det == 0).
                const axis: math.Vec3 = if (@abs(n_vec[0]) < 0.9)
                    .{ 1, 0, 0 }
                else
                    .{ 0, 1, 0 };
                t_vec = math.cross3(n_vec, axis);
                const fl = math.length3(t_vec);
                if (fl > 0.0) {
                    t_vec /= @as(math.Vec3, @splat(fl));
                }
            } else {
                t_vec /= @as(math.Vec3, @splat(tlen));
            }

            // Handedness: +1 when the reconstructed bitangent
            // (`cross(N, T)`) agrees with the accumulated B, -1
            // otherwise. Mirrors the standard MikkTSpace convention.
            const b_actual = math.cross3(n_vec, t_vec);
            const w: f32 = if (math.dot3(b_actual, accum_b[idx]) < 0.0)
                -1.0
            else
                1.0;
            v.tangent = .{ t_vec[0], t_vec[1], t_vec[2], w };
        }
    }
};

pub fn init(device: *Device, builder: Builder) !Self {
    var model = Self{
        .device = device,
        .vertexCount = @intCast(builder.vertices.items.len),
        // SAFETY: written by createVertexBuffers below before any read.
        .vertexBuffer = undefined,
    };
    try createVertexBuffers(&model, builder.vertices.items);
    errdefer model.vertexBuffer.deinit();
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
    self.vertexBuffer.deinit();
    if (self.indexBuffer) |*ib| ib.deinit();
}

fn createVertexBuffers(self: *Self, vertices: []const Vertex) !void {
    if (vertices.len < 3) return error.InvalidArgument;
    const vertex_size: c.VkDeviceSize = @sizeOf(Vertex);
    const buffer_size: c.VkDeviceSize = vertex_size * vertices.len;

    var stagingBuffer = try Buffer.init(
        self.device,
        vertex_size,
        @intCast(vertices.len),
        c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        1,
    );
    defer stagingBuffer.deinit();

    try stagingBuffer.map(c.VK_WHOLE_SIZE, 0);
    stagingBuffer.writeToBuffer(@ptrCast(vertices.ptr), c.VK_WHOLE_SIZE, 0);

    self.vertexBuffer = try Buffer.init(
        self.device,
        vertex_size,
        @intCast(vertices.len),
        c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        1,
    );
    errdefer self.vertexBuffer.deinit();

    try self.device.copyBuffer(stagingBuffer.buffer, self.vertexBuffer.buffer, buffer_size);
}

fn createIndexBuffers(self: *Self, indices: []const u32) !void {
    self.indexCount = @intCast(indices.len);
    self.hasIndexBuffer = self.indexCount > 0;
    if (!self.hasIndexBuffer) return;

    const index_size: c.VkDeviceSize = @sizeOf(u32);
    const buffer_size: c.VkDeviceSize = index_size * indices.len;

    var stagingBuffer = try Buffer.init(
        self.device,
        index_size,
        @intCast(indices.len),
        c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        1,
    );
    defer stagingBuffer.deinit();

    try stagingBuffer.map(c.VK_WHOLE_SIZE, 0);
    stagingBuffer.writeToBuffer(@ptrCast(indices.ptr), c.VK_WHOLE_SIZE, 0);

    var indexBuffer = try Buffer.init(
        self.device,
        index_size,
        @intCast(indices.len),
        c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        1,
    );
    errdefer indexBuffer.deinit();

    try self.device.copyBuffer(stagingBuffer.buffer, indexBuffer.buffer, buffer_size);
    self.indexBuffer = indexBuffer;
}

pub fn draw(self: Self, commandBuffer: c.VkCommandBuffer) void {
    if (self.hasIndexBuffer) {
        c.vkCmdDrawIndexed(commandBuffer, self.indexCount, 1, 0, 0, 0);
    } else {
        c.vkCmdDraw(commandBuffer, self.vertexCount, 1, 0, 0);
    }
}

pub fn bind(self: Self, commandBuffer: c.VkCommandBuffer) void {
    var buffers: [1]c.VkBuffer = [1]c.VkBuffer{self.vertexBuffer.buffer};
    var offsets: [1]u64 = [1]u64{0};
    c.vkCmdBindVertexBuffers(commandBuffer, 0, 1, &buffers, &offsets);

    if (self.indexBuffer) |ib| {
        c.vkCmdBindIndexBuffer(commandBuffer, ib.buffer, 0, c.VK_INDEX_TYPE_UINT32);
    }
}

test "Vertex has expected size derived from field layout" {
    const position_type = @TypeOf(@field(@as(Vertex, undefined), "position"));
    const color_type = @TypeOf(@field(@as(Vertex, undefined), "color"));
    const normal_type = @TypeOf(@field(@as(Vertex, undefined), "normal"));
    const uv_type = @TypeOf(@field(@as(Vertex, undefined), "uv"));
    const tangent_type = @TypeOf(@field(@as(Vertex, undefined), "tangent"));

    const ends = [_]usize{
        @offsetOf(Vertex, "position") + @sizeOf(position_type),
        @offsetOf(Vertex, "color") + @sizeOf(color_type),
        @offsetOf(Vertex, "normal") + @sizeOf(normal_type),
        @offsetOf(Vertex, "uv") + @sizeOf(uv_type),
        @offsetOf(Vertex, "tangent") + @sizeOf(tangent_type),
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
        .tangent = .{ 1.0, 0.0, 0.0, 1.0 },
    };
    try std.testing.expectEqual(@as(f32, 1.0), v.position[0]);
    try std.testing.expectEqual(@as(f32, 2.0), v.position[1]);
    try std.testing.expectEqual(@as(f32, 3.0), v.position[2]);
    try std.testing.expectEqual(@as(f32, 1.0), v.color[0]);
    try std.testing.expectEqual(@as(f32, 0.0), v.normal[0]);
    try std.testing.expectEqual(@as(f32, 1.0), v.normal[1]);
    try std.testing.expectEqual(@as(f32, 0.5), v.uv[0]);
    try std.testing.expectEqual(@as(f32, 0.25), v.uv[1]);
    try std.testing.expectEqual(@as(f32, 1.0), v.tangent[0]);
    try std.testing.expectEqual(@as(f32, 1.0), v.tangent[3]);
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

test "Vertex.getAttributeDescriptions has position, color, normal, uv, tangent" {
    const attrs = Vertex.getAttributeDescriptions();

    try std.testing.expectEqual(@as(usize, 5), attrs.len);

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

    // tangent @ location 4 (4-component: xyz direction + handedness sign in w)
    try std.testing.expectEqual(@as(u32, 4), attrs[4].location);
    try std.testing.expectEqual(@as(u32, 0), attrs[4].binding);
    try std.testing.expectEqual(
        @as(c_uint, c.VK_FORMAT_R32G32B32A32_SFLOAT),
        attrs[4].format,
    );
    try std.testing.expectEqual(@as(u32, @offsetOf(Vertex, "tangent")), attrs[4].offset);
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

    try std.testing.expectEqual(@as(usize, 6), fields.len);
    try std.testing.expectEqualStrings("device", fields[0].name);
    try std.testing.expectEqual(*Device, fields[0].type);
    try std.testing.expectEqualStrings("vertexCount", fields[1].name);
    try std.testing.expectEqual(u32, fields[1].type);
    try std.testing.expectEqualStrings("vertexBuffer", fields[2].name);
    try std.testing.expectEqual(Buffer, fields[2].type);
    try std.testing.expectEqualStrings("hasIndexBuffer", fields[3].name);
    try std.testing.expectEqual(bool, fields[3].type);
    try std.testing.expectEqualStrings("indexCount", fields[4].name);
    try std.testing.expectEqual(u32, fields[4].type);
    try std.testing.expectEqualStrings("indexBuffer", fields[5].name);
    try std.testing.expectEqual(?Buffer, fields[5].type);
}

test "Builder.loadModel returns InvalidObj on malformed input" {
    var builder: Builder = .{};
    defer builder.deinit(std.testing.allocator);

    // A face line with non-numeric indices makes the tinyobjloader
    // `LoadObj` call return false (with err = "Failed parse `f' line ..."),
    // which the wrapper forwards as `err_msg`. This exercises the
    // `if (err_msg != null)` log branch and the `return error.InvalidObj`
    // exit in `loadModel`.
    const bad_obj = "f a b c\n";
    try std.testing.expectError(
        error.InvalidObj,
        builder.loadModel(std.testing.allocator, bad_obj),
    );
}

test "createVertexBuffers rejects fewer than 3 vertices" {
    // SAFETY: createVertexBuffers returns InvalidArgument before touching `device`.
    var device: Device = undefined;
    var model = Self{
        .device = &device,
        .vertexCount = 0,
        // SAFETY: never read — createVertexBuffers fails fast on the length check.
        .vertexBuffer = undefined,
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

test "Model struct can be constructed with explicit undefined buffer fields" {
    // SAFETY: this test only reads `device`, `vertexCount`, `hasIndexBuffer`
    // and `indexCount`; the device pointer is never dereferenced.
    var device: Device = undefined;
    const model = Self{
        .device = &device,
        .vertexCount = 42,
        // SAFETY: not read by this test.
        .vertexBuffer = undefined,
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
