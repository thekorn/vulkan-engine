//! Thin wrapper around a `VkBuffer` + its backing `VkDeviceMemory`.
//!
//! Mirrors `LveBuffer` from the upstream Little Vulkan Engine tutorial,
//! which is itself based on Sascha Willems' `VulkanBuffer` helper. The
//! wrapper bundles the buffer handle, its device memory, and the
//! per-instance / alignment bookkeeping needed when a single buffer is
//! used to store an array of small per-frame UBO slices (each starting
//! at a multiple of `minUniformBufferOffsetAlignment`).
//!
//! Owns:
//!   - `buffer` and `memory` (destroyed in `deinit`)
//!   - the mapping returned by `vkMapMemory` (released in `unmap`, also
//!     called from `deinit`)
//!
//! Does NOT own the `*Device` it points at — that lifetime is managed
//! by the caller (typically `FirstApp` / `Model`).

const std = @import("std");

const c = @import("c.zig").c;
const Device = @import("Device.zig");
const checkSuccess = @import("utils.zig").checkSuccess;

const Self = @This();

device: *Device,
mapped: ?*anyopaque = null,
buffer: c.VkBuffer = null,
memory: c.VkDeviceMemory = null,

bufferSize: c.VkDeviceSize,
instanceCount: u32,
instanceSize: c.VkDeviceSize,
alignmentSize: c.VkDeviceSize,
usageFlags: c.VkBufferUsageFlags,
memoryPropertyFlags: c.VkMemoryPropertyFlags,

/// Round `instanceSize` up to the nearest multiple of
/// `minOffsetAlignment` (or leave it unchanged if no alignment is
/// required). Extracted as a pure function so the bit-fiddling can be
/// unit-tested without a live Vulkan device.
pub fn getAlignment(
    instanceSize: c.VkDeviceSize,
    minOffsetAlignment: c.VkDeviceSize,
) c.VkDeviceSize {
    if (minOffsetAlignment > 0) {
        return (instanceSize + minOffsetAlignment - 1) & ~(minOffsetAlignment - 1);
    }
    return instanceSize;
}

/// Create and bind a buffer big enough to hold `instanceCount` items of
/// `instanceSize` bytes, each padded up to `minOffsetAlignment`. Pass
/// `minOffsetAlignment = 1` for non-UBO buffers (vertex/index/staging)
/// where Vulkan does not impose a per-element offset alignment.
pub fn init(
    device: *Device,
    instanceSize: c.VkDeviceSize,
    instanceCount: u32,
    usageFlags: c.VkBufferUsageFlags,
    memoryPropertyFlags: c.VkMemoryPropertyFlags,
    minOffsetAlignment: c.VkDeviceSize,
) !Self {
    const alignmentSize = getAlignment(instanceSize, minOffsetAlignment);
    const bufferSize = alignmentSize * instanceCount;

    var self: Self = .{
        .device = device,
        .bufferSize = bufferSize,
        .instanceCount = instanceCount,
        .instanceSize = instanceSize,
        .alignmentSize = alignmentSize,
        .usageFlags = usageFlags,
        .memoryPropertyFlags = memoryPropertyFlags,
    };

    try device.createBuffer(
        bufferSize,
        usageFlags,
        memoryPropertyFlags,
        &self.buffer,
        &self.memory,
    );
    return self;
}

pub fn deinit(self: *Self) void {
    self.unmap();
    if (self.buffer != null) {
        c.vkDestroyBuffer(self.device.globalDevice, self.buffer, null);
        self.buffer = null;
    }
    if (self.memory != null) {
        c.vkFreeMemory(self.device.globalDevice, self.memory, null);
        self.memory = null;
    }
}

/// Map a memory range of this buffer. If successful, `self.mapped`
/// points to the specified buffer range. Pass `c.VK_WHOLE_SIZE` to map
/// the complete buffer range.
pub fn map(self: *Self, size: c.VkDeviceSize, offset: c.VkDeviceSize) !void {
    std.debug.assert(self.buffer != null and self.memory != null);
    const map_size = if (size == c.VK_WHOLE_SIZE) self.bufferSize else size;
    const map_offset = if (size == c.VK_WHOLE_SIZE) 0 else offset;
    try checkSuccess(c.vkMapMemory(
        self.device.globalDevice,
        self.memory,
        map_offset,
        map_size,
        0,
        &self.mapped,
    ));
}

/// Unmap a previously mapped memory range. Safe to call when nothing
/// is mapped.
pub fn unmap(self: *Self) void {
    if (self.mapped != null) {
        c.vkUnmapMemory(self.device.globalDevice, self.memory);
        self.mapped = null;
    }
}

/// Copy `size` bytes from `data` into the mapped buffer at `offset`.
/// Pass `c.VK_WHOLE_SIZE` to copy the entire buffer (in which case
/// `offset` is ignored, as in the upstream C++ tutorial).
pub fn writeToBuffer(
    self: *Self,
    data: *const anyopaque,
    size: c.VkDeviceSize,
    offset: c.VkDeviceSize,
) void {
    std.debug.assert(self.mapped != null);
    const mapped_bytes: [*]u8 = @ptrCast(self.mapped.?);
    const src_bytes: [*]const u8 = @ptrCast(data);
    if (size == c.VK_WHOLE_SIZE) {
        @memcpy(mapped_bytes[0..self.bufferSize], src_bytes[0..self.bufferSize]);
    } else {
        @memcpy(mapped_bytes[offset .. offset + size], src_bytes[0..size]);
    }
}

/// Flush a memory range of the buffer to make host writes visible to
/// the device. Only required for non-coherent memory.
pub fn flush(self: *Self, size: c.VkDeviceSize, offset: c.VkDeviceSize) !void {
    const mappedRange: c.VkMappedMemoryRange = .{
        .sType = c.VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
        .memory = self.memory,
        .offset = offset,
        .size = size,
    };
    try checkSuccess(c.vkFlushMappedMemoryRanges(self.device.globalDevice, 1, &mappedRange));
}

/// Invalidate a memory range of the buffer to make device writes
/// visible to the host. Only required for non-coherent memory.
pub fn invalidate(self: *Self, size: c.VkDeviceSize, offset: c.VkDeviceSize) !void {
    const mappedRange: c.VkMappedMemoryRange = .{
        .sType = c.VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
        .memory = self.memory,
        .offset = offset,
        .size = size,
    };
    try checkSuccess(c.vkInvalidateMappedMemoryRanges(self.device.globalDevice, 1, &mappedRange));
}

/// Build a `VkDescriptorBufferInfo` covering `size` bytes starting at
/// `offset`.
pub fn descriptorInfo(
    self: *const Self,
    size: c.VkDeviceSize,
    offset: c.VkDeviceSize,
) c.VkDescriptorBufferInfo {
    return .{
        .buffer = self.buffer,
        .offset = offset,
        .range = size,
    };
}

// ---------------------------------------------------------------------
// Index-keyed convenience helpers (one slice per frame in flight)
// ---------------------------------------------------------------------

/// Copy `instanceSize` bytes from `data` into the slice at
/// `index * alignmentSize`.
pub fn writeToIndex(self: *Self, data: *const anyopaque, index: usize) void {
    self.writeToBuffer(data, self.instanceSize, @as(c.VkDeviceSize, index) * self.alignmentSize);
}

/// Flush the slice at `index * alignmentSize`.
pub fn flushIndex(self: *Self, index: usize) !void {
    try self.flush(self.alignmentSize, @as(c.VkDeviceSize, index) * self.alignmentSize);
}

/// Descriptor info covering exactly the slice at `index * alignmentSize`.
pub fn descriptorInfoForIndex(self: *const Self, index: usize) c.VkDescriptorBufferInfo {
    return self.descriptorInfo(self.alignmentSize, @as(c.VkDeviceSize, index) * self.alignmentSize);
}

/// Invalidate the slice at `index * alignmentSize`.
pub fn invalidateIndex(self: *Self, index: usize) !void {
    try self.invalidate(self.alignmentSize, @as(c.VkDeviceSize, index) * self.alignmentSize);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

test "getAlignment returns instanceSize unchanged when no alignment is required" {
    try std.testing.expectEqual(@as(c.VkDeviceSize, 32), getAlignment(32, 0));
    try std.testing.expectEqual(@as(c.VkDeviceSize, 1), getAlignment(1, 0));
    try std.testing.expectEqual(@as(c.VkDeviceSize, 4096), getAlignment(4096, 0));
}

test "getAlignment rounds up to the next multiple of the alignment" {
    // 80 bytes rounded up to 256-byte alignment -> 256
    try std.testing.expectEqual(@as(c.VkDeviceSize, 256), getAlignment(80, 256));
    // 256 already aligned -> stays 256
    try std.testing.expectEqual(@as(c.VkDeviceSize, 256), getAlignment(256, 256));
    // 257 just over -> rounds up to 512
    try std.testing.expectEqual(@as(c.VkDeviceSize, 512), getAlignment(257, 256));
    // 1 byte at 64-byte alignment -> 64
    try std.testing.expectEqual(@as(c.VkDeviceSize, 64), getAlignment(1, 64));
}

test "getAlignment is a no-op when instanceSize is already a multiple of alignment" {
    try std.testing.expectEqual(@as(c.VkDeviceSize, 128), getAlignment(128, 64));
    try std.testing.expectEqual(@as(c.VkDeviceSize, 192), getAlignment(192, 64));
}

/// Build a `Buffer` whose `mapped` pointer aliases a caller-provided
/// byte slice, so the pure-logic copy paths (`writeToBuffer`,
/// `writeToIndex`) can be exercised without a live Vulkan device.
///
/// The returned buffer leaves `device`, `buffer` and `memory` as
/// dummy/null values; never call `init`-allocated paths like `map`,
/// `flush`, `invalidate`, or `deinit` on it.
fn fakeMappedBuffer(
    storage: []u8,
    instanceSize: c.VkDeviceSize,
    instanceCount: u32,
    alignmentSize: c.VkDeviceSize,
) Self {
    return .{
        // Safety: tests below never dereference `device`, but the field
        // is non-optional. Cast a sentinel pointer instead of leaving
        // it `undefined` so accidental dereferences segfault loudly.
        .device = @ptrFromInt(0x1000),
        .mapped = @ptrCast(storage.ptr),
        .buffer = null,
        .memory = null,
        .bufferSize = storage.len,
        .instanceCount = instanceCount,
        .instanceSize = instanceSize,
        .alignmentSize = alignmentSize,
        .usageFlags = 0,
        .memoryPropertyFlags = 0,
    };
}

test "writeToBuffer with VK_WHOLE_SIZE copies bufferSize bytes from data" {
    var dst: [16]u8 = @splat(0xAA);
    const src: [16]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    var buf = fakeMappedBuffer(&dst, 16, 1, 16);
    buf.writeToBuffer(@ptrCast(&src), c.VK_WHOLE_SIZE, 0);
    try std.testing.expectEqualSlices(u8, &src, &dst);
}

test "writeToBuffer with VK_WHOLE_SIZE ignores offset" {
    // VK_WHOLE_SIZE branch always writes the full bufferSize starting
    // at offset 0, regardless of the offset argument — matches the C++
    // tutorial's behavior.
    var dst: [8]u8 = @splat(0xCC);
    const src: [8]u8 = .{ 9, 9, 9, 9, 9, 9, 9, 9 };
    var buf = fakeMappedBuffer(&dst, 8, 1, 8);
    buf.writeToBuffer(@ptrCast(&src), c.VK_WHOLE_SIZE, 4);
    try std.testing.expectEqualSlices(u8, &src, &dst);
}

test "writeToBuffer with explicit size+offset writes only that slice" {
    var dst: [16]u8 = @splat(0);
    const src: [4]u8 = .{ 0xDE, 0xAD, 0xBE, 0xEF };
    var buf = fakeMappedBuffer(&dst, 16, 1, 16);
    buf.writeToBuffer(@ptrCast(&src), 4, 8);

    // Bytes before the offset must remain untouched.
    for (dst[0..8]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try std.testing.expectEqualSlices(u8, &src, dst[8..12]);
    // Bytes after the write must remain untouched.
    for (dst[12..16]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "writeToIndex writes instanceSize bytes at index*alignmentSize" {
    // Two 4-byte instances, each padded up to 8-byte alignment, in a
    // 16-byte buffer. Index 1 should land at offset 8 and write 4
    // bytes (NOT the full alignmentSize).
    var dst: [16]u8 = @splat(0);
    const src: [4]u8 = .{ 1, 2, 3, 4 };
    var buf = fakeMappedBuffer(&dst, 4, 2, 8);
    buf.writeToIndex(@ptrCast(&src), 1);

    // Slice [0..8] (index 0) untouched.
    for (dst[0..8]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    // First 4 bytes of slice [8..16] = src.
    try std.testing.expectEqualSlices(u8, &src, dst[8..12]);
    // Trailing alignment padding [12..16] untouched.
    for (dst[12..16]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "writeToIndex at index 0 writes at offset 0" {
    var dst: [16]u8 = @splat(0xFF);
    const src: [4]u8 = .{ 7, 8, 9, 10 };
    var buf = fakeMappedBuffer(&dst, 4, 2, 8);
    buf.writeToIndex(@ptrCast(&src), 0);
    try std.testing.expectEqualSlices(u8, &src, dst[0..4]);
    // Padding [4..8] and the next slice [8..16] must be untouched.
    for (dst[4..16]) |b| try std.testing.expectEqual(@as(u8, 0xFF), b);
}

test "descriptorInfo populates buffer/offset/range" {
    var dst: [16]u8 = @splat(0);
    const buf = fakeMappedBuffer(&dst, 16, 1, 16);
    const info = buf.descriptorInfo(8, 4);
    try std.testing.expectEqual(buf.buffer, info.buffer);
    try std.testing.expectEqual(@as(c.VkDeviceSize, 4), info.offset);
    try std.testing.expectEqual(@as(c.VkDeviceSize, 8), info.range);
}

test "descriptorInfoForIndex computes offset as index*alignmentSize" {
    var dst: [32]u8 = @splat(0);
    const buf = fakeMappedBuffer(&dst, 4, 4, 8);

    const info0 = buf.descriptorInfoForIndex(0);
    try std.testing.expectEqual(@as(c.VkDeviceSize, 0), info0.offset);
    try std.testing.expectEqual(@as(c.VkDeviceSize, 8), info0.range);

    const info2 = buf.descriptorInfoForIndex(2);
    try std.testing.expectEqual(@as(c.VkDeviceSize, 16), info2.offset);
    try std.testing.expectEqual(@as(c.VkDeviceSize, 8), info2.range);
}

test "unmap is a no-op when nothing is mapped" {
    // Construct a Buffer that was never mapped (no `device` access
    // because the `mapped == null` branch short-circuits the call to
    // `vkUnmapMemory`).
    var buf: Self = .{
        .device = @ptrFromInt(0x1000),
        .mapped = null,
        .buffer = null,
        .memory = null,
        .bufferSize = 0,
        .instanceCount = 0,
        .instanceSize = 0,
        .alignmentSize = 0,
        .usageFlags = 0,
        .memoryPropertyFlags = 0,
    };
    buf.unmap();
    try std.testing.expectEqual(@as(?*anyopaque, null), buf.mapped);
}

test "deinit on an empty (uninitialized) Buffer is a safe no-op" {
    // `deinit` must tolerate a Buffer whose underlying Vulkan handles
    // were never created (e.g. when a higher-level `errdefer` runs
    // before `init` filled in the buffer/memory). All three branches
    // (`mapped`, `buffer`, `memory`) short-circuit on null without
    // touching `device`.
    var buf: Self = .{
        .device = @ptrFromInt(0x1000),
        .mapped = null,
        .buffer = null,
        .memory = null,
        .bufferSize = 0,
        .instanceCount = 0,
        .instanceSize = 0,
        .alignmentSize = 0,
        .usageFlags = 0,
        .memoryPropertyFlags = 0,
    };
    buf.deinit();
    try std.testing.expectEqual(@as(c.VkBuffer, null), buf.buffer);
    try std.testing.expectEqual(@as(c.VkDeviceMemory, null), buf.memory);
    try std.testing.expectEqual(@as(?*anyopaque, null), buf.mapped);
}

test "Buffer has expected fields and types" {
    const fields = @typeInfo(Self).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 10), fields.len);
    try std.testing.expectEqual(*Device, @FieldType(Self, "device"));
    try std.testing.expectEqual(?*anyopaque, @FieldType(Self, "mapped"));
    try std.testing.expectEqual(c.VkBuffer, @FieldType(Self, "buffer"));
    try std.testing.expectEqual(c.VkDeviceMemory, @FieldType(Self, "memory"));
    try std.testing.expectEqual(c.VkDeviceSize, @FieldType(Self, "bufferSize"));
    try std.testing.expectEqual(u32, @FieldType(Self, "instanceCount"));
    try std.testing.expectEqual(c.VkDeviceSize, @FieldType(Self, "instanceSize"));
    try std.testing.expectEqual(c.VkDeviceSize, @FieldType(Self, "alignmentSize"));
    try std.testing.expectEqual(c.VkBufferUsageFlags, @FieldType(Self, "usageFlags"));
    try std.testing.expectEqual(c.VkMemoryPropertyFlags, @FieldType(Self, "memoryPropertyFlags"));
}
