const std = @import("std");
const builtin = @import("builtin");

const c = @import("c.zig").c;
const Vulkan = @import("Vulkan.zig");
const Window = @import("Window.zig");

const checkSuccess = @import("utils.zig").checkSuccess;

const Self = @This();
alloc: std.mem.Allocator,
window: *Window,
enable_validation_layers: bool,
surface: c.VkSurfaceKHR,
vulkanInstance: Vulkan,
physicalDevice: c.VkPhysicalDevice,
/// Cached `vkGetPhysicalDeviceProperties` result for the selected GPU.
/// Exposed so callers can read limits such as
/// `properties.limits.minUniformBufferOffsetAlignment` without
/// re-querying the driver each frame.
properties: c.VkPhysicalDeviceProperties,
globalDevice: c.VkDevice,
graphicsQueue: c.VkQueue,
presentQueue: c.VkQueue,
commandPool: c.VkCommandPool,

pub fn init(alloc: std.mem.Allocator, window: *Window) !*Self {
    const enable_validation_layers = builtin.mode == .Debug;

    const vulkan = try Vulkan.init(alloc, enable_validation_layers);
    // SAFETY: filled in by glfwCreateWindowSurface in window.create_surface below.
    var surface: c.VkSurfaceKHR = undefined;
    try window.create_surface(vulkan.instance, &surface);

    // SAFETY: filled in by vkGetDeviceQueue inside createLogicalDevice below.
    var graphicsQueue: c.VkQueue = undefined;
    // SAFETY: filled in by vkGetDeviceQueue inside createLogicalDevice below.
    var presentQueue: c.VkQueue = undefined;
    // SAFETY: filled in by vkCreateDevice inside createLogicalDevice below.
    var globalDevice: c.VkDevice = undefined;

    const physicalDevice = try pickPhysicalDevice(alloc, vulkan, surface);

    try Vulkan.createLogicalDevice(
        alloc,
        physicalDevice,
        surface,
        &globalDevice,
        &graphicsQueue,
        &presentQueue,
        enable_validation_layers,
    );

    // SAFETY: filled in by vkCreateCommandPool inside createCommandPool below.
    var commandPool: c.VkCommandPool = undefined;
    try createCommandPool(alloc, physicalDevice, surface, globalDevice, &commandPool);

    // SAFETY: written by vkGetPhysicalDeviceProperties below before any read.
    var properties: c.VkPhysicalDeviceProperties = undefined;
    c.vkGetPhysicalDeviceProperties(physicalDevice, &properties);

    const self = try alloc.create(Self);
    self.* = .{
        .alloc = alloc,
        .window = window,
        .surface = surface,
        .enable_validation_layers = enable_validation_layers,
        .vulkanInstance = vulkan,
        .physicalDevice = physicalDevice,
        .properties = properties,
        .globalDevice = globalDevice,
        .graphicsQueue = graphicsQueue,
        .presentQueue = presentQueue,
        .commandPool = commandPool,
    };
    return self;
}

pub fn deinit(self: *Self) void {
    c.vkDestroyCommandPool(self.globalDevice, self.commandPool, null);
    c.vkDestroyDevice(self.globalDevice, null);

    if (self.enable_validation_layers) {
        //DestroyDebugUtilsMessengerEXT(instance, debugMessenger, null);
        //TODO: Implement validation layer deinit
    }
    c.vkDestroySurfaceKHR(self.vulkanInstance.instance, self.surface, null);
    self.vulkanInstance.deinit();
    self.alloc.destroy(self);
}

fn pickPhysicalDevice(alloc: std.mem.Allocator, vulkan: Vulkan, surface: c.VkSurfaceKHR) !c.VkPhysicalDevice {
    var deviceCount: u32 = 0;

    try checkSuccess(c.vkEnumeratePhysicalDevices(vulkan.instance, &deviceCount, null));

    if (deviceCount == 0) {
        return error.FailedToFindGPUsWithVulkanSupport;
    }

    const devices = try alloc.alloc(c.VkPhysicalDevice, deviceCount);
    defer alloc.free(devices);
    try checkSuccess(c.vkEnumeratePhysicalDevices(vulkan.instance, &deviceCount, devices.ptr));

    const physicalDevice: c.VkPhysicalDevice = for (devices) |device| {
        if (try isDeviceSuitable(alloc, device, surface)) {
            break device;
        }
    } else return error.FailedToFindSuitableGPU;

    // SAFETY: written by vkGetPhysicalDeviceProperties below before any read.
    var properties: c.VkPhysicalDeviceProperties = undefined;

    c.vkGetPhysicalDeviceProperties(physicalDevice, &properties);
    std.log.scoped(.device).debug("physical device: {s}", .{properties.deviceName});

    return physicalDevice;
}

fn isDeviceSuitable(alloc: std.mem.Allocator, device: c.VkPhysicalDevice, surface: c.VkSurfaceKHR) !bool {
    const indices = try Vulkan.findQueueFamilies(alloc, device, surface);

    const extensionsSupported = try Vulkan.checkDeviceExtensionSupport(alloc, device);

    var swapChainAdequate = false;
    if (extensionsSupported) {
        var swapChainSupport = try Vulkan.querySwapChainSupport(alloc, device, surface);
        defer swapChainSupport.deinit();
        swapChainAdequate = swapChainSupport.formats.len != 0 and swapChainSupport.presentModes.len != 0;
    }

    return indices.isComplete() and extensionsSupported and swapChainAdequate;
}

fn createCommandPool(
    alloc: std.mem.Allocator,
    device: c.VkPhysicalDevice,
    surface: c.VkSurfaceKHR,
    globalDevice: c.VkDevice,
    commandPool: *c.VkCommandPool,
) !void {
    const queueFamilyIndices = try Vulkan.findQueueFamilies(alloc, device, surface);

    const poolInfo = c.VkCommandPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .queueFamilyIndex = queueFamilyIndices.graphicsFamily.?,
        .pNext = null,
        .flags = c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT | c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
    };

    try checkSuccess(c.vkCreateCommandPool(globalDevice, &poolInfo, null, commandPool));
}

pub fn createShaderModule(
    self: *Self,
    shaderCode: []const u8,
) !c.VkShaderModule {
    std.debug.assert(shaderCode.len % @sizeOf(u32) == 0);

    // Allocate properly aligned memory for the shader code
    // Vulkan requires pCode to be aligned to 4 bytes (u32 alignment)
    const alignedCode = try self.alloc.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(@alignOf(u32)), shaderCode.len);
    defer self.alloc.free(alignedCode);
    @memcpy(alignedCode, shaderCode);

    const createInfo = c.VkShaderModuleCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = alignedCode.len,
        .pCode = @ptrCast(@alignCast(alignedCode.ptr)),
        .pNext = null,
        .flags = 0,
    };
    // SAFETY: written by vkCreateShaderModule below before any read.
    var shader_module: c.VkShaderModule = undefined;
    try checkSuccess(c.vkCreateShaderModule(self.globalDevice, &createInfo, null, &shader_module));
    return shader_module;
}

pub fn getSwapChainSupport(self: *Self) !Vulkan.SwapChainSupportDetails {
    return try Vulkan.querySwapChainSupport(self.alloc, self.physicalDevice, self.surface);
}

pub fn findSupportedFormat(self: *Self, candidates: []const c.VkFormat, tiling: c.VkImageTiling, features: c.VkFormatFeatureFlags) !c.VkFormat {
    for (candidates) |format| {
        // SAFETY: written by vkGetPhysicalDeviceFormatProperties below before any read.
        var props: c.VkFormatProperties = undefined;
        c.vkGetPhysicalDeviceFormatProperties(self.physicalDevice, format, &props);

        if (tiling == c.VK_IMAGE_TILING_LINEAR and (props.linearTilingFeatures & features) == features) {
            return format;
        } else if (tiling == c.VK_IMAGE_TILING_OPTIMAL and (props.optimalTilingFeatures & features) == features) {
            return format;
        }
    }
    return error.NoSupportedFormatFound;
}

pub fn createImageWithInfo(self: *Self, imageInfo: *c.VkImageCreateInfo, properties: c.VkMemoryPropertyFlags, image: *c.VkImage, imageMemory: *c.VkDeviceMemory) !void {
    try checkSuccess(c.vkCreateImage(self.globalDevice, imageInfo, null, image));

    // SAFETY: written by vkGetImageMemoryRequirements below before any read.
    var memRequirements: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(self.globalDevice, image.*, &memRequirements);

    const allocInfo = c.VkMemoryAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = memRequirements.size,
        .memoryTypeIndex = try self.findMemoryType(memRequirements.memoryTypeBits, properties),
    };

    try checkSuccess(c.vkAllocateMemory(self.globalDevice, &allocInfo, null, imageMemory));
    try checkSuccess(c.vkBindImageMemory(self.globalDevice, image.*, imageMemory.*, 0));
}

pub fn findMemoryType(self: *Self, typeFilter: u32, properties: c.VkMemoryPropertyFlags) !u32 {
    // SAFETY: written by vkGetPhysicalDeviceMemoryProperties below before any read.
    var memProperties: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(self.physicalDevice, &memProperties);
    return pickMemoryType(&memProperties, typeFilter, properties);
}

/// Pure-logic helper: pick the first memory type that:
///   1. is enabled in `typeFilter` (a bitmask from
///      `VkMemoryRequirements.memoryTypeBits`), and
///   2. has all of `properties` set in its `propertyFlags`.
///
/// Extracted from `findMemoryType` so it can be exercised in tests
/// without a live `VkPhysicalDevice`.
pub fn pickMemoryType(
    memProperties: *const c.VkPhysicalDeviceMemoryProperties,
    typeFilter: u32,
    properties: c.VkMemoryPropertyFlags,
) !u32 {
    for (0..memProperties.memoryTypeCount) |i| {
        const bit: u32 = @as(u32, 1) << @intCast(i);
        if ((typeFilter & bit) != 0 and
            (memProperties.memoryTypes[i].propertyFlags & properties) == properties)
        {
            return @intCast(i);
        }
    }
    return error.NoSuitableMemoryTypeFound;
}

pub fn createBuffer(
    self: *Self,
    size: u64,
    usage: c.VkBufferUsageFlags,
    properties: c.VkMemoryPropertyFlags,
    buffer: *c.VkBuffer,
    bufferMemory: *c.VkDeviceMemory,
) !void {
    const bufferInfo = c.VkBufferCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = usage,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
    };

    try checkSuccess(c.vkCreateBuffer(self.globalDevice, &bufferInfo, null, buffer));

    // SAFETY: written by vkGetBufferMemoryRequirements below before any read.
    var memRequirements: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(self.globalDevice, buffer.*, &memRequirements);

    const allocInfo = c.VkMemoryAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = memRequirements.size,
        .memoryTypeIndex = try self.findMemoryType(memRequirements.memoryTypeBits, properties),
    };

    try checkSuccess(c.vkAllocateMemory(self.globalDevice, &allocInfo, null, bufferMemory));
    try checkSuccess(c.vkBindBufferMemory(self.globalDevice, buffer.*, bufferMemory.*, 0));
}

pub fn beginSingleTimeCommands(self: *Self) !c.VkCommandBuffer {
    const allocInfo = c.VkCommandBufferAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandPool = self.commandPool,
        .commandBufferCount = 1,
    };

    // SAFETY: written by vkAllocateCommandBuffers below before any read.
    var commandBuffer: c.VkCommandBuffer = undefined;
    try checkSuccess(c.vkAllocateCommandBuffers(self.globalDevice, &allocInfo, &commandBuffer));
    errdefer c.vkFreeCommandBuffers(self.globalDevice, self.commandPool, 1, &commandBuffer);

    const beginInfo = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    try checkSuccess(c.vkBeginCommandBuffer(commandBuffer, &beginInfo));
    return commandBuffer;
}

pub fn endSingleTimeCommands(self: *Self, commandBuffer: c.VkCommandBuffer) !void {
    var cb: c.VkCommandBuffer = commandBuffer;
    // Free the command buffer on any failure before/within submit. After
    // vkQueueWaitIdle returns successfully the command buffer is no longer
    // in use, so we free it unconditionally at the end of the happy path.
    errdefer c.vkFreeCommandBuffers(self.globalDevice, self.commandPool, 1, &cb);

    try checkSuccess(c.vkEndCommandBuffer(commandBuffer));

    const submitInfo = c.VkSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &cb,
    };

    try checkSuccess(c.vkQueueSubmit(self.graphicsQueue, 1, &submitInfo, null));
    try checkSuccess(c.vkQueueWaitIdle(self.graphicsQueue));

    c.vkFreeCommandBuffers(self.globalDevice, self.commandPool, 1, &cb);
}

pub fn copyBuffer(self: *Self, srcBuffer: c.VkBuffer, dstBuffer: c.VkBuffer, size: c.VkDeviceSize) !void {
    const commandBuffer = try self.beginSingleTimeCommands();

    const copyRegion = c.VkBufferCopy{
        .srcOffset = 0,
        .dstOffset = 0,
        .size = size,
    };
    c.vkCmdCopyBuffer(commandBuffer, srcBuffer, dstBuffer, 1, &copyRegion);

    try self.endSingleTimeCommands(commandBuffer);
}

/// Insert a pipeline barrier that transitions every mip level of
/// `image` from `oldLayout` to `newLayout`. Only the two transitions
/// the texture-upload path needs are wired up:
///
///   1. `UNDEFINED → TRANSFER_DST_OPTIMAL` — taken right after the
///      image is created, before `vkCmdCopyBufferToImage`.
///   2. `TRANSFER_DST_OPTIMAL → SHADER_READ_ONLY_OPTIMAL` — taken
///      after the copy so the fragment shader can sample the result.
///
/// Any other combination triggers `error.UnsupportedLayoutTransition`
/// so missing barrier wiring fails loudly instead of silently
/// producing validation errors.
pub fn transitionImageLayout(
    self: *Self,
    image: c.VkImage,
    oldLayout: c.VkImageLayout,
    newLayout: c.VkImageLayout,
    mipLevels: u32,
) !void {
    // Resolve the barrier masks *before* allocating a single-time
    // command buffer so an unsupported layout pair doesn't leak one
    // from `self.commandPool` on the early-return path.
    var srcAccessMask: c.VkAccessFlags = 0;
    var dstAccessMask: c.VkAccessFlags = 0;
    var srcStage: c.VkPipelineStageFlags = 0;
    var dstStage: c.VkPipelineStageFlags = 0;

    if (oldLayout == c.VK_IMAGE_LAYOUT_UNDEFINED and
        newLayout == c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
    {
        srcAccessMask = 0;
        dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        srcStage = c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
        dstStage = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
    } else if (oldLayout == c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL and
        newLayout == c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
    {
        srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        srcStage = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
        dstStage = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    } else {
        return error.UnsupportedLayoutTransition;
    }

    const commandBuffer = try self.beginSingleTimeCommands();

    const barrier: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .oldLayout = oldLayout,
        .newLayout = newLayout,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = mipLevels,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .srcAccessMask = srcAccessMask,
        .dstAccessMask = dstAccessMask,
    };

    c.vkCmdPipelineBarrier(
        commandBuffer,
        srcStage,
        dstStage,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );

    try self.endSingleTimeCommands(commandBuffer);
}

/// Copy the contents of `buffer` (tightly packed RGBA8 pixels of
/// `width × height`) into mip level 0 of `image`. The image must
/// currently be in `VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL` (the
/// caller is expected to call `transitionImageLayout` first).
pub fn copyBufferToImage(
    self: *Self,
    buffer: c.VkBuffer,
    image: c.VkImage,
    width: u32,
    height: u32,
) !void {
    const commandBuffer = try self.beginSingleTimeCommands();

    const region: c.VkBufferImageCopy = .{
        .bufferOffset = 0,
        // `bufferRowLength = 0` + `bufferImageHeight = 0` means "tightly
        // packed" — the source rows are exactly `width` texels wide.
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
        .imageExtent = .{ .width = width, .height = height, .depth = 1 },
    };

    c.vkCmdCopyBufferToImage(
        commandBuffer,
        buffer,
        image,
        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        1,
        &region,
    );

    try self.endSingleTimeCommands(commandBuffer);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

/// Build a `VkPhysicalDeviceMemoryProperties` populated with `types`
/// for use in `pickMemoryType` tests. Heaps are left zeroed since the
/// search only reads `memoryTypes[i].propertyFlags`.
fn makeMemProps(
    types: []const c.VkMemoryType,
) c.VkPhysicalDeviceMemoryProperties {
    var props: c.VkPhysicalDeviceMemoryProperties = std.mem.zeroes(c.VkPhysicalDeviceMemoryProperties);
    props.memoryTypeCount = @intCast(types.len);
    for (types, 0..) |t, i| props.memoryTypes[i] = t;
    return props;
}

test "pickMemoryType returns the first matching index" {
    const types = [_]c.VkMemoryType{
        .{ .propertyFlags = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, .heapIndex = 0 },
        .{ .propertyFlags = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, .heapIndex = 0 },
        .{ .propertyFlags = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, .heapIndex = 0 },
    };
    const props = makeMemProps(types[0..]);

    // typeFilter selects all three types; we ask for HOST_VISIBLE|HOST_COHERENT.
    const idx = try pickMemoryType(
        &props,
        0b111,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    );
    try std.testing.expectEqual(@as(u32, 1), idx);
}

test "pickMemoryType honors typeFilter and skips filtered-out types" {
    const types = [_]c.VkMemoryType{
        .{ .propertyFlags = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, .heapIndex = 0 },
        .{ .propertyFlags = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, .heapIndex = 0 },
    };
    const props = makeMemProps(types[0..]);

    // Only type index 1 is allowed by the filter (bit 1 set, bit 0 clear).
    const idx = try pickMemoryType(
        &props,
        0b10,
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    );
    try std.testing.expectEqual(@as(u32, 1), idx);
}

test "pickMemoryType requires ALL requested property bits to be set" {
    const types = [_]c.VkMemoryType{
        // Has HOST_VISIBLE only — missing HOST_COHERENT, so should not match.
        .{ .propertyFlags = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, .heapIndex = 0 },
        // Has both bits → first valid match.
        .{ .propertyFlags = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, .heapIndex = 0 },
    };
    const props = makeMemProps(types[0..]);

    const idx = try pickMemoryType(
        &props,
        0b11,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    );
    try std.testing.expectEqual(@as(u32, 1), idx);
}

test "pickMemoryType returns NoSuitableMemoryTypeFound when nothing matches" {
    const types = [_]c.VkMemoryType{
        .{ .propertyFlags = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, .heapIndex = 0 },
    };
    const props = makeMemProps(types[0..]);

    // Ask for HOST_VISIBLE which is not present in any type.
    try std.testing.expectError(
        error.NoSuitableMemoryTypeFound,
        pickMemoryType(&props, 0b1, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT),
    );
}

test "pickMemoryType returns NoSuitableMemoryTypeFound for an empty type list" {
    const props = makeMemProps(&.{});
    try std.testing.expectError(
        error.NoSuitableMemoryTypeFound,
        pickMemoryType(&props, 0xFFFF, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
    );
}

test "pickMemoryType with properties=0 matches the first filter-allowed type" {
    const types = [_]c.VkMemoryType{
        .{ .propertyFlags = 0, .heapIndex = 0 },
        .{ .propertyFlags = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, .heapIndex = 0 },
    };
    const props = makeMemProps(types[0..]);

    // properties=0 means "no required bits", so the first filter-allowed
    // type wins regardless of its flags.
    const idx = try pickMemoryType(&props, 0b11, 0);
    try std.testing.expectEqual(@as(u32, 0), idx);
}

test "Device has expected fields and types" {
    const fields = @typeInfo(Self).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 11), fields.len);
    try std.testing.expectEqual(std.mem.Allocator, @FieldType(Self, "alloc"));
    try std.testing.expectEqual(*Window, @FieldType(Self, "window"));
    try std.testing.expectEqual(bool, @FieldType(Self, "enable_validation_layers"));
    try std.testing.expectEqual(c.VkSurfaceKHR, @FieldType(Self, "surface"));
    try std.testing.expectEqual(Vulkan, @FieldType(Self, "vulkanInstance"));
    try std.testing.expectEqual(c.VkPhysicalDevice, @FieldType(Self, "physicalDevice"));
    try std.testing.expectEqual(c.VkPhysicalDeviceProperties, @FieldType(Self, "properties"));
    try std.testing.expectEqual(c.VkDevice, @FieldType(Self, "globalDevice"));
    try std.testing.expectEqual(c.VkQueue, @FieldType(Self, "graphicsQueue"));
    try std.testing.expectEqual(c.VkQueue, @FieldType(Self, "presentQueue"));
    try std.testing.expectEqual(c.VkCommandPool, @FieldType(Self, "commandPool"));
}
