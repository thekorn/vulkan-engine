const std = @import("std");
const builtin = @import("builtin");

const c = @import("c.zig").c;
const Vulkan = @import("Vulkan.zig");
const Window = @import("Window.zig");

const checkSuccess = @import("utils.zig").checkSuccess;

const deviceExtensions = [_][*:0]const u8{c.VK_KHR_SWAPCHAIN_EXTENSION_NAME};

const Self = @This();
window: *Window,
enable_validation_layers: bool,
surface: c.VkSurfaceKHR,
instance: Vulkan,
physicalDevice: c.VkPhysicalDevice,

pub fn init(alloc: std.mem.Allocator, window: *Window) !Self {
    const enable_validation_layers = builtin.mode == .Debug;

    const instance = try Vulkan.init(alloc, enable_validation_layers);
    var surface: c.VkSurfaceKHR = undefined;
    try createSurface(instance, window, &surface);

    const physicalDevice = try pickPhysicalDevice(alloc, instance, surface);

    return .{
        .window = window,
        .surface = surface,
        .enable_validation_layers = enable_validation_layers,
        .instance = instance,
        .physicalDevice = physicalDevice,
    };
}

pub fn deinit(self: *Self) void {
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
    std.debug.print("physical device: {s}\n", .{properties.deviceName});

    return physicalDevice;
}

fn isDeviceSuitable(alloc: std.mem.Allocator, device: c.VkPhysicalDevice, surface: c.VkSurfaceKHR) !bool {
    const indices = try findQueueFamilies(alloc, device, surface);

    const extensionsSupported = try checkDeviceExtensionSupport(alloc, device);

    var swapChainAdequate = false;
    if (extensionsSupported) {
        var swapChainSupport = try querySwapChainSupport(alloc, device, surface);
        defer swapChainSupport.deinit();
        swapChainAdequate = swapChainSupport.formats.items.len != 0 and swapChainSupport.presentModes.items.len != 0;
    }

    return indices.isComplete() and extensionsSupported and swapChainAdequate;
}

const QueueFamilyIndices = struct {
    graphicsFamily: ?u32,
    presentFamily: ?u32,

    fn init() QueueFamilyIndices {
        return QueueFamilyIndices{
            .graphicsFamily = null,
            .presentFamily = null,
        };
    }

    fn isComplete(self: QueueFamilyIndices) bool {
        return self.graphicsFamily != null and self.presentFamily != null;
    }
};

fn findQueueFamilies(
    alloc: std.mem.Allocator,
    device: c.VkPhysicalDevice,
    surface: c.VkSurfaceKHR,
) !QueueFamilyIndices {
    var indices = QueueFamilyIndices.init();

    var queueFamilyCount: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queueFamilyCount, null);

    const queueFamilies = try alloc.alloc(c.VkQueueFamilyProperties, queueFamilyCount);
    defer alloc.free(queueFamilies);
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queueFamilyCount, queueFamilies.ptr);

    var i: u32 = 0;
    for (queueFamilies) |queueFamily| {
        if (queueFamily.queueCount > 0 and
            queueFamily.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0)
        {
            indices.graphicsFamily = i;
        }

        var presentSupport: c.VkBool32 = 0;

        try checkSuccess(c.vkGetPhysicalDeviceSurfaceSupportKHR(device, i, surface, &presentSupport));

        if (queueFamily.queueCount > 0 and presentSupport != 0) {
            indices.presentFamily = i;
        }

        if (indices.isComplete()) {
            break;
        }

        i += 1;
    }

    return indices;
}

fn checkDeviceExtensionSupport(alloc: std.mem.Allocator, device: c.VkPhysicalDevice) !bool {
    var extensionCount: u32 = undefined;
    try checkSuccess(c.vkEnumerateDeviceExtensionProperties(device, null, &extensionCount, null));

    const availableExtensions = try alloc.alloc(c.VkExtensionProperties, extensionCount);
    defer alloc.free(availableExtensions);
    try checkSuccess(c.vkEnumerateDeviceExtensionProperties(device, null, &extensionCount, availableExtensions.ptr));

    const CStrHashMap = std.hash_map.HashMap(
        [*:0]const u8,
        void,
        CStrContext,
        std.hash_map.default_max_load_percentage,
    );
    var requiredExtensions = CStrHashMap.init(alloc);
    defer requiredExtensions.deinit();
    for (deviceExtensions) |device_ext| {
        _ = try requiredExtensions.put(device_ext, {});
    }

    for (availableExtensions) |extension| {
        _ = requiredExtensions.remove(@ptrCast(&extension.extensionName));
    }

    return requiredExtensions.count() == 0;
}

const CStrContext = struct {
    const CSelf = @This();
    pub fn hash(self: CSelf, a: [*:0]const u8) u64 {
        _ = self;
        // FNV 32-bit hash
        var h: u32 = 2166136261;
        var i: usize = 0;
        while (a[i] != 0) : (i += 1) {
            h ^= a[i];
            h *%= 16777619;
        }
        return h;
    }

    pub fn eql(self: CSelf, a: [*:0]const u8, b: [*:0]const u8) bool {
        _ = self;
        return std.mem.orderZ(u8, a, b) == .eq;
    }
};

fn querySwapChainSupport(
    alloc: std.mem.Allocator,
    device: c.VkPhysicalDevice,
    surface: c.VkSurfaceKHR,
) !SwapChainSupportDetails {
    var details = SwapChainSupportDetails.init(alloc);

    try checkSuccess(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &details.capabilities));

    var formatCount: u32 = undefined;
    try checkSuccess(c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &formatCount, null));

    if (formatCount != 0) {
        try details.formats.resize(alloc, formatCount);
        try checkSuccess(c.vkGetPhysicalDeviceSurfaceFormatsKHR(
            device,
            surface,
            &formatCount,
            details.formats.items.ptr,
        ));
    }

    var presentModeCount: u32 = undefined;
    try checkSuccess(c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &presentModeCount, null));

    if (presentModeCount != 0) {
        try details.presentModes.resize(alloc, presentModeCount);
        try checkSuccess(c.vkGetPhysicalDeviceSurfacePresentModesKHR(
            device,
            surface,
            &presentModeCount,
            details.presentModes.items.ptr,
        ));
    }

    return details;
}

const SwapChainSupportDetails = struct {
    capabilities: c.VkSurfaceCapabilitiesKHR,
    formats: std.ArrayList(c.VkSurfaceFormatKHR),
    presentModes: std.ArrayList(c.VkPresentModeKHR),
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) SwapChainSupportDetails {
        const formats: std.ArrayList(c.VkSurfaceFormatKHR) = .empty;
        const presentModes: std.ArrayList(c.VkPresentModeKHR) = .empty;

        const result = SwapChainSupportDetails{
            .capabilities = undefined,
            .formats = formats,
            .presentModes = presentModes,
            .alloc = alloc,
        };
        //const slice = std.mem.sliceAsBytes(@as(*[1]c.VkSurfaceCapabilitiesKHR, &result.capabilities)[0..1]);
        //std.mem.set(u8, slice, 0);
        return result;
    }

    fn deinit(self: *SwapChainSupportDetails) void {
        self.formats.deinit(self.alloc);
        self.presentModes.deinit(self.alloc);
    }
};
