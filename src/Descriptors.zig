//! Descriptor set layouts, pools and writers.
//!
//! Direct port of `lve_descriptors.{hpp,cpp}` from the upstream Little
//! Vulkan Engine tutorial. Provides three small wrappers:
//!
//!   - `DescriptorSetLayout` (+ `Builder`) — owns a `VkDescriptorSetLayout`
//!     and the bindings map used by `DescriptorWriter` to validate writes.
//!   - `DescriptorPool` (+ `Builder`) — owns a `VkDescriptorPool` and
//!     exposes allocate / free / reset helpers.
//!   - `DescriptorWriter` — accumulates `VkWriteDescriptorSet`s and either
//!     allocates a new descriptor set from a pool (`build`) or updates
//!     an existing one (`overwrite`).
//!
//! None of these own a `*Device` — that lifetime is managed by the
//! caller (typically `FirstApp`).

const std = @import("std");

const c = @import("c.zig").c;
const Device = @import("Device.zig");
const checkSuccess = @import("utils.zig").checkSuccess;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// =====================================================================
// DescriptorSetLayout
// =====================================================================

pub const DescriptorSetLayout = struct {
    alloc: Allocator,
    device: *Device,
    descriptorSetLayout: c.VkDescriptorSetLayout,
    /// Kept around so `DescriptorWriter` can validate that a write
    /// targets a binding that actually exists in the layout, and that
    /// the binding's descriptor count is compatible with the write.
    bindings: std.AutoHashMapUnmanaged(u32, c.VkDescriptorSetLayoutBinding),

    pub const Builder = struct {
        alloc: Allocator,
        device: *Device,
        bindings: std.AutoHashMapUnmanaged(u32, c.VkDescriptorSetLayoutBinding) = .empty,

        pub fn init(alloc: Allocator, device: *Device) Builder {
            return .{ .alloc = alloc, .device = device };
        }

        /// Release any partially-populated bindings storage. Only needs
        /// to be called on a `Builder` that was not consumed by `build`
        /// (which transfers ownership of the bindings map).
        pub fn deinit(self: *Builder) void {
            self.bindings.deinit(self.alloc);
        }

        pub fn addBinding(
            self: *Builder,
            binding: u32,
            descriptorType: c.VkDescriptorType,
            stageFlags: c.VkShaderStageFlags,
            count: u32,
        ) !void {
            std.debug.assert(!self.bindings.contains(binding));
            const layoutBinding: c.VkDescriptorSetLayoutBinding = .{
                .binding = binding,
                .descriptorType = descriptorType,
                .descriptorCount = count,
                .stageFlags = stageFlags,
                .pImmutableSamplers = null,
            };
            try self.bindings.put(self.alloc, binding, layoutBinding);
        }

        /// Build the layout, transferring ownership of the bindings map
        /// into the returned `DescriptorSetLayout`. The moved-from
        /// field is reset to `.empty` so a stray `Builder.deinit`
        /// after `build` is a safe no-op rather than a double-free
        /// (calling `deinit` is still unnecessary on the happy path).
        pub fn build(self: *Builder) !DescriptorSetLayout {
            const bindings = self.bindings;
            self.bindings = .empty;
            return DescriptorSetLayout.init(self.alloc, self.device, bindings);
        }
    };

    pub fn init(
        alloc: Allocator,
        device: *Device,
        bindings: std.AutoHashMapUnmanaged(u32, c.VkDescriptorSetLayoutBinding),
    ) !DescriptorSetLayout {
        // `bindings` ownership is moved in; release it if anything
        // below fails before we hand it to the returned struct.
        var owned_bindings = bindings;
        errdefer owned_bindings.deinit(alloc);

        var setLayoutBindings: ArrayList(c.VkDescriptorSetLayoutBinding) = .empty;
        defer setLayoutBindings.deinit(alloc);
        try setLayoutBindings.ensureTotalCapacity(alloc, owned_bindings.count());

        var it = owned_bindings.valueIterator();
        while (it.next()) |b| {
            setLayoutBindings.appendAssumeCapacity(b.*);
        }

        const descriptorSetLayoutInfo: c.VkDescriptorSetLayoutCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = @intCast(setLayoutBindings.items.len),
            .pBindings = setLayoutBindings.items.ptr,
        };

        // SAFETY: written by vkCreateDescriptorSetLayout below before any read.
        var descriptorSetLayout: c.VkDescriptorSetLayout = undefined;
        try checkSuccess(c.vkCreateDescriptorSetLayout(
            device.globalDevice,
            &descriptorSetLayoutInfo,
            null,
            &descriptorSetLayout,
        ));

        return .{
            .alloc = alloc,
            .device = device,
            .descriptorSetLayout = descriptorSetLayout,
            .bindings = owned_bindings,
        };
    }

    pub fn deinit(self: *DescriptorSetLayout) void {
        c.vkDestroyDescriptorSetLayout(
            self.device.globalDevice,
            self.descriptorSetLayout,
            null,
        );
        self.bindings.deinit(self.alloc);
    }

    pub fn getDescriptorSetLayout(self: *const DescriptorSetLayout) c.VkDescriptorSetLayout {
        return self.descriptorSetLayout;
    }
};

// =====================================================================
// DescriptorPool
// =====================================================================

pub const DescriptorPool = struct {
    device: *Device,
    descriptorPool: c.VkDescriptorPool,

    pub const Builder = struct {
        alloc: Allocator,
        device: *Device,
        poolSizes: ArrayList(c.VkDescriptorPoolSize) = .empty,
        maxSets: u32 = 1000,
        poolFlags: c.VkDescriptorPoolCreateFlags = 0,

        pub fn init(alloc: Allocator, device: *Device) Builder {
            return .{ .alloc = alloc, .device = device };
        }

        /// Release any partially-populated pool-size storage. Only
        /// needs to be called on a `Builder` that was not consumed by
        /// `build`.
        pub fn deinit(self: *Builder) void {
            self.poolSizes.deinit(self.alloc);
        }

        pub fn addPoolSize(
            self: *Builder,
            descriptorType: c.VkDescriptorType,
            count: u32,
        ) !void {
            try self.poolSizes.append(self.alloc, .{
                .type = descriptorType,
                .descriptorCount = count,
            });
        }

        pub fn setPoolFlags(self: *Builder, flags: c.VkDescriptorPoolCreateFlags) void {
            self.poolFlags = flags;
        }

        pub fn setMaxSets(self: *Builder, count: u32) void {
            self.maxSets = count;
        }

        /// Build the pool. Consumes the builder's `poolSizes` (copies
        /// them into the `VkDescriptorPool`) and then frees the
        /// staging `ArrayList`, so the builder doesn't need a separate
        /// `deinit` call on the happy path.
        pub fn build(self: *Builder) !DescriptorPool {
            defer self.poolSizes.deinit(self.alloc);
            return DescriptorPool.init(
                self.device,
                self.maxSets,
                self.poolFlags,
                self.poolSizes.items,
            );
        }
    };

    pub fn init(
        device: *Device,
        maxSets: u32,
        poolFlags: c.VkDescriptorPoolCreateFlags,
        poolSizes: []const c.VkDescriptorPoolSize,
    ) !DescriptorPool {
        const descriptorPoolInfo: c.VkDescriptorPoolCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .poolSizeCount = @intCast(poolSizes.len),
            .pPoolSizes = poolSizes.ptr,
            .maxSets = maxSets,
            .flags = poolFlags,
        };

        // SAFETY: written by vkCreateDescriptorPool below before any read.
        var descriptorPool: c.VkDescriptorPool = undefined;
        try checkSuccess(c.vkCreateDescriptorPool(
            device.globalDevice,
            &descriptorPoolInfo,
            null,
            &descriptorPool,
        ));

        return .{ .device = device, .descriptorPool = descriptorPool };
    }

    pub fn deinit(self: *DescriptorPool) void {
        c.vkDestroyDescriptorPool(self.device.globalDevice, self.descriptorPool, null);
    }

    /// Allocate one descriptor set with `descriptorSetLayout`. Returns
    /// `false` if allocation failed (e.g. the pool is full) — the C++
    /// tutorial notes that a real engine would want a pool manager to
    /// allocate a fresh pool in that case, but that is beyond the
    /// current scope.
    pub fn allocateDescriptor(
        self: *const DescriptorPool,
        descriptorSetLayout: c.VkDescriptorSetLayout,
        descriptor: *c.VkDescriptorSet,
    ) bool {
        const allocInfo: c.VkDescriptorSetAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = self.descriptorPool,
            .pSetLayouts = &descriptorSetLayout,
            .descriptorSetCount = 1,
        };
        return c.vkAllocateDescriptorSets(self.device.globalDevice, &allocInfo, descriptor) == c.VK_SUCCESS;
    }

    pub fn freeDescriptors(
        self: *const DescriptorPool,
        descriptors: []const c.VkDescriptorSet,
    ) !void {
        try checkSuccess(c.vkFreeDescriptorSets(
            self.device.globalDevice,
            self.descriptorPool,
            @intCast(descriptors.len),
            descriptors.ptr,
        ));
    }

    pub fn resetPool(self: *DescriptorPool) !void {
        try checkSuccess(c.vkResetDescriptorPool(
            self.device.globalDevice,
            self.descriptorPool,
            0,
        ));
    }
};

// =====================================================================
// DescriptorWriter
// =====================================================================

pub const DescriptorWriter = struct {
    alloc: Allocator,
    setLayout: *DescriptorSetLayout,
    pool: *DescriptorPool,
    writes: ArrayList(c.VkWriteDescriptorSet) = .empty,

    pub fn init(
        alloc: Allocator,
        setLayout: *DescriptorSetLayout,
        pool: *DescriptorPool,
    ) DescriptorWriter {
        return .{ .alloc = alloc, .setLayout = setLayout, .pool = pool };
    }

    pub fn deinit(self: *DescriptorWriter) void {
        self.writes.deinit(self.alloc);
    }

    /// `bufferInfo` must live until `build` / `overwrite` is called —
    /// only the pointer is stored in the `VkWriteDescriptorSet`.
    pub fn writeBuffer(
        self: *DescriptorWriter,
        binding: u32,
        bufferInfo: *const c.VkDescriptorBufferInfo,
    ) !void {
        const bindingDescription = self.setLayout.bindings.get(binding) orelse {
            std.debug.panic("Layout does not contain binding {d}", .{binding});
        };
        std.debug.assert(bindingDescription.descriptorCount == 1);

        try self.writes.append(self.alloc, .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .descriptorType = bindingDescription.descriptorType,
            .dstBinding = binding,
            .pBufferInfo = bufferInfo,
            .descriptorCount = 1,
        });
    }

    /// `imageInfo` must live until `build` / `overwrite` is called.
    pub fn writeImage(
        self: *DescriptorWriter,
        binding: u32,
        imageInfo: *const c.VkDescriptorImageInfo,
    ) !void {
        const bindingDescription = self.setLayout.bindings.get(binding) orelse {
            std.debug.panic("Layout does not contain binding {d}", .{binding});
        };
        std.debug.assert(bindingDescription.descriptorCount == 1);

        try self.writes.append(self.alloc, .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .descriptorType = bindingDescription.descriptorType,
            .dstBinding = binding,
            .pImageInfo = imageInfo,
            .descriptorCount = 1,
        });
    }

    /// Allocate a fresh descriptor set from `pool` and apply all
    /// queued writes to it. Returns `false` if the pool allocation
    /// failed.
    pub fn build(self: *DescriptorWriter, set: *c.VkDescriptorSet) !bool {
        if (!self.pool.allocateDescriptor(self.setLayout.getDescriptorSetLayout(), set)) {
            return false;
        }
        self.overwrite(set.*);
        return true;
    }

    /// Apply all queued writes to an existing descriptor set.
    pub fn overwrite(self: *DescriptorWriter, set: c.VkDescriptorSet) void {
        for (self.writes.items) |*w| {
            w.dstSet = set;
        }
        c.vkUpdateDescriptorSets(
            self.pool.device.globalDevice,
            @intCast(self.writes.items.len),
            self.writes.items.ptr,
            0,
            null,
        );
    }
};

// =====================================================================
// Tests
// =====================================================================

test "DescriptorSetLayout.Builder.addBinding stores the binding metadata" {
    // SAFETY: tests below never dereference `device`; cast a sentinel
    // pointer instead of leaving it `undefined` so accidental
    // dereferences segfault loudly.
    const dummy_device: *Device = @ptrFromInt(0x1000);
    var builder = DescriptorSetLayout.Builder.init(std.testing.allocator, dummy_device);
    defer builder.deinit();

    try builder.addBinding(
        0,
        c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        c.VK_SHADER_STAGE_VERTEX_BIT,
        1,
    );
    try builder.addBinding(
        2,
        c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        c.VK_SHADER_STAGE_FRAGMENT_BIT,
        3,
    );

    try std.testing.expectEqual(@as(u32, 2), builder.bindings.count());

    const b0 = builder.bindings.get(0).?;
    try std.testing.expectEqual(@as(u32, 0), b0.binding);
    try std.testing.expectEqual(
        @as(c.VkDescriptorType, c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER),
        b0.descriptorType,
    );
    try std.testing.expectEqual(
        @as(c.VkShaderStageFlags, c.VK_SHADER_STAGE_VERTEX_BIT),
        b0.stageFlags,
    );
    try std.testing.expectEqual(@as(u32, 1), b0.descriptorCount);

    const b2 = builder.bindings.get(2).?;
    try std.testing.expectEqual(@as(u32, 3), b2.descriptorCount);
    try std.testing.expectEqual(
        @as(c.VkDescriptorType, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER),
        b2.descriptorType,
    );
}

test "DescriptorPool.Builder collects pool sizes and tunables" {
    const dummy_device: *Device = @ptrFromInt(0x1000);
    var builder = DescriptorPool.Builder.init(std.testing.allocator, dummy_device);
    defer builder.deinit();

    try builder.addPoolSize(c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 4);
    try builder.addPoolSize(c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 8);
    builder.setMaxSets(16);
    builder.setPoolFlags(c.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT);

    try std.testing.expectEqual(@as(usize, 2), builder.poolSizes.items.len);
    try std.testing.expectEqual(
        @as(c.VkDescriptorType, c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER),
        builder.poolSizes.items[0].type,
    );
    try std.testing.expectEqual(@as(u32, 4), builder.poolSizes.items[0].descriptorCount);
    try std.testing.expectEqual(@as(u32, 8), builder.poolSizes.items[1].descriptorCount);
    try std.testing.expectEqual(@as(u32, 16), builder.maxSets);
    try std.testing.expectEqual(
        @as(c.VkDescriptorPoolCreateFlags, c.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT),
        builder.poolFlags,
    );
}

test "DescriptorSetLayout has expected fields and types" {
    const fields = @typeInfo(DescriptorSetLayout).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 4), fields.len);
    try std.testing.expectEqual(Allocator, @FieldType(DescriptorSetLayout, "alloc"));
    try std.testing.expectEqual(*Device, @FieldType(DescriptorSetLayout, "device"));
    try std.testing.expectEqual(
        c.VkDescriptorSetLayout,
        @FieldType(DescriptorSetLayout, "descriptorSetLayout"),
    );
}

test "DescriptorPool has expected fields and types" {
    const fields = @typeInfo(DescriptorPool).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqual(*Device, @FieldType(DescriptorPool, "device"));
    try std.testing.expectEqual(
        c.VkDescriptorPool,
        @FieldType(DescriptorPool, "descriptorPool"),
    );
}

test "DescriptorWriter has expected fields and types" {
    const fields = @typeInfo(DescriptorWriter).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 4), fields.len);
    try std.testing.expectEqual(Allocator, @FieldType(DescriptorWriter, "alloc"));
    try std.testing.expectEqual(*DescriptorSetLayout, @FieldType(DescriptorWriter, "setLayout"));
    try std.testing.expectEqual(*DescriptorPool, @FieldType(DescriptorWriter, "pool"));
    try std.testing.expectEqual(
        ArrayList(c.VkWriteDescriptorSet),
        @FieldType(DescriptorWriter, "writes"),
    );
}
