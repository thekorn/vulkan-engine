const std = @import("std");
const builtin = @import("builtin");

const c = @import("c.zig").c;
const Vulkan = @import("Vulkan.zig");
const Window = @import("Window.zig");

const checkSuccess = @import("utils.zig").checkSuccess;

const Self = @This();
window: *Window,
enable_validation_layers: bool,
surface: c.VkSurfaceKHR,
instance: Vulkan,
physicalDevice: c.VkPhysicalDevice,
globalDevice: c.VkDevice,
graphicsQueue: c.VkQueue,
presentQueue: c.VkQueue,

pub fn init(alloc: std.mem.Allocator, window: *Window) !Self {
    const enable_validation_layers = builtin.mode == .Debug;

    const instance = try Vulkan.init(alloc, enable_validation_layers);
    var surface: c.VkSurfaceKHR = undefined;
    try createSurface(instance, window, &surface);

    var graphicsQueue: c.VkQueue = undefined;
    var presentQueue: c.VkQueue = undefined;
    var globalDevice: c.VkDevice = undefined;

    const physicalDevice = try pickPhysicalDevice(alloc, instance, surface);
    try Vulkan.createLogicalDevice(
        alloc,
        physicalDevice,
        surface,
        &globalDevice,
        &graphicsQueue,
        &presentQueue,
        enable_validation_layers,
    );

    return .{
        .window = window,
        .surface = surface,
        .enable_validation_layers = enable_validation_layers,
        .instance = instance,
        .physicalDevice = physicalDevice,
        .globalDevice = globalDevice,
        .graphicsQueue = graphicsQueue,
        .presentQueue = presentQueue,
    };
}

pub fn deinit(self: *Self) void {
    c.vkDestroyDevice(self.globalDevice, null);

    if (self.enable_validation_layers) {
        //DestroyDebugUtilsMessengerEXT(instance, debugMessenger, null);
        //TODO: Implement validation layer deinit
    }
    c.vkDestroySurfaceKHR(self.instance.instance, self.surface, null);
    self.instance.deinit();
}

fn createSurface(vulkan: Vulkan, window: *Window, surface: *c.VkSurfaceKHR) !void {
    try checkSuccess(c.glfwCreateWindowSurface(vulkan.instance, window.instance, null, surface));
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
