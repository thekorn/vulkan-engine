const std = @import("std");
const builtin = @import("builtin");

const c = @import("c.zig").c;
const Vulkan = @import("Vulkan.zig");
const Window = @import("Window.zig");

const checkSuccess = @import("utils.zig").checkSuccess;

const Self = @This();
allocator: std.mem.Allocator,
window: *Window,
enable_validation_layers: bool,
surface: c.VkSurfaceKHR,
vulkanInstance: Vulkan,
physicalDevice: c.VkPhysicalDevice,
globalDevice: c.VkDevice,
graphicsQueue: c.VkQueue,
presentQueue: c.VkQueue,
commandPool: c.VkCommandPool,

pub fn init(alloc: std.mem.Allocator, window: *Window) !Self {
    const enable_validation_layers = builtin.mode == .Debug;

    const vulkan = try Vulkan.init(alloc, enable_validation_layers);
    var surface: c.VkSurfaceKHR = undefined;
    try window.create_surface(vulkan.instance, &surface);

    var graphicsQueue: c.VkQueue = undefined;
    var presentQueue: c.VkQueue = undefined;
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

    var commandPool: c.VkCommandPool = undefined;
    try createCommandPool(alloc, physicalDevice, surface, globalDevice, &commandPool);

    return .{
        .allocator = alloc,
        .window = window,
        .surface = surface,
        .enable_validation_layers = enable_validation_layers,
        .vulkanInstance = vulkan,
        .physicalDevice = physicalDevice,
        .globalDevice = globalDevice,
        .graphicsQueue = graphicsQueue,
        .presentQueue = presentQueue,
        .commandPool = commandPool,
    };
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
        swapChainAdequate = swapChainSupport.formats.items.len != 0 and swapChainSupport.presentModes.items.len != 0;
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
        .flags = 0,
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
    const alignedCode = try self.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(@alignOf(u32)), shaderCode.len);
    defer self.allocator.free(alignedCode);
    @memcpy(alignedCode, shaderCode);

    const createInfo = c.VkShaderModuleCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = alignedCode.len,
        .pCode = @ptrCast(@alignCast(alignedCode.ptr)),
        .pNext = null,
        .flags = 0,
    };
    var shader_module: c.VkShaderModule = undefined;
    try checkSuccess(c.vkCreateShaderModule(self.globalDevice, &createInfo, null, &shader_module));
    return shader_module;
}
