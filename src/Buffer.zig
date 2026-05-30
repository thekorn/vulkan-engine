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
