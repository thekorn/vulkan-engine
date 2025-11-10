const std = @import("std");
const builtin = @import("builtin");

const c = @import("c.zig").c;
const checkSuccess = @import("utils.zig").checkSuccess;

const deviceExtensions = [_][*:0]const u8{
    c.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
    c.VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME,
};
const validationLayers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};

const Self = @This();
instance: c.VkInstance,

fn getExtensionNames(
    alloc: std.mem.Allocator,
    enable_validation_layers: bool,
) ![][*c]const u8 {
    var glfwExtensionCount: u32 = 0;
    var glfwExtensions = c.glfwGetRequiredInstanceExtensions(&glfwExtensionCount);

    var extensions: std.ArrayList([*c]const u8) = .empty;
    defer extensions.deinit(alloc);

    // if this is NULL the vulkan is likely init before glfw - change order
    std.debug.assert(glfwExtensionCount > 0);
    for (glfwExtensions[0..glfwExtensionCount]) |ext| {
        try extensions.append(alloc, ext);
    }

    const extra_extensions = switch (builtin.os.tag) {
        // see: https://vulkan.lunarg.com/doc/sdk/1.3.283.0/mac/getting_started.html
        // section `Common Problems - Encountered VK_ERROR_INCOMPATIBLE_DRIVER`
        .ios, .macos, .tvos, .watchos => &[_][*]const u8{
            c.VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME,
            c.VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME,
        },
        else => &.{},
    };

    try extensions.appendSlice(alloc, extra_extensions);

    if (enable_validation_layers) {
        try extensions.append(alloc, c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
    }

    return extensions.toOwnedSlice(alloc);
}

//TODO: Implement this function
fn checkValidationLayerSupport() bool {
    return true;
}

fn debugCallback(
    message_severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT,
    message_types: c.VkDebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const c.VkDebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(.c) c_uint {
    _ = message_severity;
    _ = message_types;
    _ = p_user_data;
    b: {
        const msg = (p_callback_data orelse break :b).pMessage orelse break :b;
        std.log.scoped(.validation).warn("{s}", .{msg});
        return c.VK_FALSE;
    }
    std.log.scoped(.validation).warn("unrecognized validation layer debug message", .{});
    return c.VK_FALSE;
}

pub fn init(alloc: std.mem.Allocator, enable_validation_layers: bool) !Self {
    var instance: c.VkInstance = undefined;

    if (enable_validation_layers and !checkValidationLayerSupport()) {
        return error.NoValidationLayerSupport;
    }

    const enabled_layers: []const [*:0]const u8 = if (enable_validation_layers) &validationLayers else &.{};

    const extensions = try getExtensionNames(alloc, enable_validation_layers);
    for (extensions) |ext| {
        std.log.scoped(.extensions).debug("Extension: {s}", .{ext});
    }
    defer alloc.free(extensions);

    var appInfo = c.VkApplicationInfo{
        .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Vulkan Engine",
        .applicationVersion = c.VK_MAKE_VERSION(1, 0, 0),
        .pEngineName = "Zig",
        .engineVersion = c.VK_MAKE_VERSION(1, 0, 0),
        .apiVersion = c.VK_API_VERSION_1_4,
    };

    var debugCreateInfo = c.VkDebugUtilsMessengerCreateInfoEXT{
        .sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
        .messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
        .pfnUserCallback = debugCallback,
        .pUserData = null,
    };

    const info = c.VkInstanceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .flags = c.VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
        .enabledExtensionCount = @intCast(extensions.len),
        .ppEnabledExtensionNames = extensions.ptr,
        .pApplicationInfo = &appInfo,
        .enabledLayerCount = @intCast(enabled_layers.len),
        .ppEnabledLayerNames = enabled_layers.ptr,
        .pNext = if (enable_validation_layers) &debugCreateInfo else null,
    };

    switch (c.vkCreateInstance(&info, null, &instance)) {
        c.VK_SUCCESS => {},
        c.VK_ERROR_OUT_OF_HOST_MEMORY => return error.OutOfHostMemory,
        c.VK_ERROR_OUT_OF_DEVICE_MEMORY => return error.OutOfDeviceMemory,
        c.VK_ERROR_INITIALIZATION_FAILED => return error.InitializationFailed,
        c.VK_ERROR_LAYER_NOT_PRESENT => return error.LayerNotPresent,
        c.VK_ERROR_EXTENSION_NOT_PRESENT => return error.ExtensionNotPresent,
        c.VK_ERROR_INCOMPATIBLE_DRIVER => return error.IncompatibleDriver,
        else => unreachable,
    }
    return .{
        .instance = instance,
    };
}

pub fn deinit(self: Self) void {
    c.vkDestroyInstance(self.instance, null);
}

pub fn createLogicalDevice(
    alloc: std.mem.Allocator,
    physicalDevice: c.VkPhysicalDevice,
    surface: c.VkSurfaceKHR,
    globalDevice: *c.VkDevice,
    graphicsQueue: *c.VkQueue,
    presentQueue: *c.VkQueue,
    enableValidationLayers: bool,
) !void {
    const indices = try findQueueFamilies(alloc, physicalDevice, surface);

    var queueCreateInfos: std.ArrayList(c.VkDeviceQueueCreateInfo) = .empty;
    defer queueCreateInfos.deinit(alloc);
    const all_queue_families = [_]u32{ indices.graphicsFamily.?, indices.presentFamily.? };
    const uniqueQueueFamilies = if (indices.graphicsFamily.? == indices.presentFamily.?)
        all_queue_families[0..1]
    else
        all_queue_families[0..2];

    var queuePriority: f32 = 1.0;
    for (uniqueQueueFamilies) |queueFamily| {
        const queueCreateInfo = c.VkDeviceQueueCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = queueFamily,
            .queueCount = 1,
            .pQueuePriorities = &queuePriority,
            .pNext = null,
            .flags = 0,
        };
        try queueCreateInfos.append(alloc, queueCreateInfo);
    }

    const deviceFeatures: c.VkPhysicalDeviceFeatures = .{};

    const createInfo = c.VkDeviceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,

        .queueCreateInfoCount = @intCast(queueCreateInfos.items.len),
        .pQueueCreateInfos = queueCreateInfos.items.ptr,

        .pEnabledFeatures = &deviceFeatures,

        .enabledExtensionCount = @intCast(deviceExtensions.len),
        .ppEnabledExtensionNames = &deviceExtensions,
        .enabledLayerCount = if (enableValidationLayers) @intCast(validationLayers.len) else 0,
        .ppEnabledLayerNames = if (enableValidationLayers) &validationLayers else null,

        .pNext = null,
        .flags = 0,
    };

    try checkSuccess(c.vkCreateDevice(physicalDevice, &createInfo, null, globalDevice));

    c.vkGetDeviceQueue(globalDevice.*, indices.graphicsFamily.?, 0, graphicsQueue);
    c.vkGetDeviceQueue(globalDevice.*, indices.presentFamily.?, 0, presentQueue);
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

    pub fn isComplete(self: QueueFamilyIndices) bool {
        return self.graphicsFamily != null and self.presentFamily != null;
    }
};

pub fn findQueueFamilies(
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

pub fn checkDeviceExtensionSupport(alloc: std.mem.Allocator, device: c.VkPhysicalDevice) !bool {
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

pub fn querySwapChainSupport(
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

    pub fn deinit(self: *SwapChainSupportDetails) void {
        self.formats.deinit(self.alloc);
        self.presentModes.deinit(self.alloc);
    }
};
