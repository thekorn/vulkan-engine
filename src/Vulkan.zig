const std = @import("std");
const builtin = @import("builtin");

const c = @import("c.zig").c;
const checkSuccess = @import("utils.zig").checkSuccess;

const deviceExtensions = [_][*:0]const u8{
    c.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
    c.VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME,
};
const validationLayers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
};

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

fn checkValidationLayerSupport(alloc: std.mem.Allocator) !bool {
    var layer_count: u32 = 0;
    _ = c.vkEnumerateInstanceLayerProperties(&layer_count, null);

    const available_layers = try alloc.alloc(c.VkLayerProperties, layer_count);
    defer alloc.free(available_layers);

    _ = c.vkEnumerateInstanceLayerProperties(&layer_count, available_layers.ptr);

    for (validationLayers) |layer_name| {
        var layer_found = false;

        for (available_layers) |layer_props| {
            const available_name = std.mem.sliceTo(&layer_props.layerName, 0);
            const requested_name = std.mem.span(layer_name);

            if (std.mem.eql(u8, available_name, requested_name)) {
                layer_found = true;
                break;
            }
        }

        if (!layer_found) {
            std.log.scoped(.validation).warn("Validation layer not found: {s}", .{layer_name});
            return false;
        }
    }

    return true;
}

fn debugCallback(
    message_severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT,
    message_types: c.VkDebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const c.VkDebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(.c) c_uint {
    _ = message_types;
    _ = p_user_data;
    const log = std.log.scoped(.validation);
    b: {
        const msg = (p_callback_data orelse break :b).pMessage orelse break :b;
        if (message_severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT != 0) {
            log.err("{s}", .{msg});
        } else if (message_severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT != 0) {
            log.warn("{s}", .{msg});
        } else if (message_severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT != 0) {
            log.info("{s}", .{msg});
        } else {
            log.debug("{s}", .{msg});
        }
        return c.VK_FALSE;
    }
    log.warn("unrecognized validation layer debug message", .{});
    return c.VK_FALSE;
}

pub fn init(alloc: std.mem.Allocator, enable_validation_layers: bool) !Self {
    // SAFETY: written by vkCreateInstance below before any read.
    var instance: c.VkInstance = undefined;

    if (enable_validation_layers and !try checkValidationLayerSupport(alloc)) {
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
    // SAFETY: written by vkEnumerateDeviceExtensionProperties below before any read.
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

    // SAFETY: written by vkGetPhysicalDeviceSurfaceFormatsKHR below before any read.
    var formatCount: u32 = undefined;
    try checkSuccess(c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &formatCount, null));

    if (formatCount != 0) {
        details.formats = try alloc.alloc(c.VkSurfaceFormatKHR, formatCount);
        try checkSuccess(c.vkGetPhysicalDeviceSurfaceFormatsKHR(
            device,
            surface,
            &formatCount,
            details.formats.ptr,
        ));
    }

    // SAFETY: written by vkGetPhysicalDeviceSurfacePresentModesKHR below before any read.
    var presentModeCount: u32 = undefined;
    try checkSuccess(c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &presentModeCount, null));

    if (presentModeCount != 0) {
        details.presentModes = try alloc.alloc(c.VkPresentModeKHR, presentModeCount);
        try checkSuccess(c.vkGetPhysicalDeviceSurfacePresentModesKHR(
            device,
            surface,
            &presentModeCount,
            details.presentModes.ptr,
        ));
    }

    return details;
}

pub const SwapChainSupportDetails = struct {
    capabilities: c.VkSurfaceCapabilitiesKHR,
    formats: []c.VkSurfaceFormatKHR,
    presentModes: []c.VkPresentModeKHR,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) SwapChainSupportDetails {
        return SwapChainSupportDetails{
            // SAFETY: filled in by vkGetPhysicalDeviceSurfaceCapabilitiesKHR
            // in querySwapChainSupport before any read.
            .capabilities = undefined,
            .formats = &.{},
            .presentModes = &.{},
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *SwapChainSupportDetails) void {
        _ = self;
        //self.formats.deinit(self.alloc);
        //self.presentModes.deinit(self.alloc);
    }
};

test "QueueFamilyIndices.init returns null fields" {
    const indices = QueueFamilyIndices.init();
    try std.testing.expect(indices.graphicsFamily == null);
    try std.testing.expect(indices.presentFamily == null);
}

test "QueueFamilyIndices.isComplete is false when both fields are null" {
    const indices = QueueFamilyIndices.init();
    try std.testing.expect(!indices.isComplete());
}

test "QueueFamilyIndices.isComplete is false when only graphicsFamily is set" {
    var indices = QueueFamilyIndices.init();
    indices.graphicsFamily = 0;
    try std.testing.expect(!indices.isComplete());
}

test "QueueFamilyIndices.isComplete is false when only presentFamily is set" {
    var indices = QueueFamilyIndices.init();
    indices.presentFamily = 1;
    try std.testing.expect(!indices.isComplete());
}

test "QueueFamilyIndices.isComplete is true when both fields are set" {
    var indices = QueueFamilyIndices.init();
    indices.graphicsFamily = 0;
    indices.presentFamily = 1;
    try std.testing.expect(indices.isComplete());
}

test "QueueFamilyIndices.isComplete handles graphicsFamily == presentFamily" {
    var indices = QueueFamilyIndices.init();
    indices.graphicsFamily = 2;
    indices.presentFamily = 2;
    try std.testing.expect(indices.isComplete());
}

test "CStrContext.eql returns true for identical strings" {
    const ctx = CStrContext{};
    const a: [*:0]const u8 = "VK_KHR_swapchain";
    const b: [*:0]const u8 = "VK_KHR_swapchain";
    try std.testing.expect(ctx.eql(a, b));
}

test "CStrContext.eql returns false for different strings" {
    const ctx = CStrContext{};
    const a: [*:0]const u8 = "VK_KHR_swapchain";
    const b: [*:0]const u8 = "VK_KHR_portability_subset";
    try std.testing.expect(!ctx.eql(a, b));
}

test "CStrContext.eql returns false for strings with shared prefix" {
    const ctx = CStrContext{};
    const a: [*:0]const u8 = "abc";
    const b: [*:0]const u8 = "abcd";
    try std.testing.expect(!ctx.eql(a, b));
}

test "CStrContext.eql returns true for empty strings" {
    const ctx = CStrContext{};
    const a: [*:0]const u8 = "";
    const b: [*:0]const u8 = "";
    try std.testing.expect(ctx.eql(a, b));
}

test "CStrContext.hash produces identical hashes for identical strings" {
    const ctx = CStrContext{};
    const a: [*:0]const u8 = "VK_KHR_swapchain";
    const b: [*:0]const u8 = "VK_KHR_swapchain";
    try std.testing.expectEqual(ctx.hash(a), ctx.hash(b));
}

test "CStrContext.hash produces different hashes for different strings" {
    const ctx = CStrContext{};
    const a: [*:0]const u8 = "VK_KHR_swapchain";
    const b: [*:0]const u8 = "VK_KHR_portability_subset";
    try std.testing.expect(ctx.hash(a) != ctx.hash(b));
}

test "CStrContext is usable as a HashMap context" {
    const Map = std.hash_map.HashMap(
        [*:0]const u8,
        u32,
        CStrContext,
        std.hash_map.default_max_load_percentage,
    );
    var map = Map.init(std.testing.allocator);
    defer map.deinit();

    try map.put("alpha", 1);
    try map.put("beta", 2);

    try std.testing.expectEqual(@as(?u32, 1), map.get("alpha"));
    try std.testing.expectEqual(@as(?u32, 2), map.get("beta"));
    try std.testing.expectEqual(@as(?u32, null), map.get("gamma"));
    try std.testing.expectEqual(@as(u32, 2), map.count());

    try std.testing.expect(map.remove("alpha"));
    try std.testing.expectEqual(@as(u32, 1), map.count());
}

//test "SwapChainSupportDetails.init creates empty lists" {
//    var details = SwapChainSupportDetails.init(std.testing.allocator);
//    defer details.deinit();
//
//    try std.testing.expectEqual(@as(usize, 0), details.formats.len);
//    try std.testing.expectEqual(@as(usize, 0), details.presentModes.len);
//}
//
//test "SwapChainSupportDetails can grow and deinit cleanly" {
//    var details = SwapChainSupportDetails.init(std.testing.allocator);
//    defer details.deinit();
//
//    try details.formats.resize(std.testing.allocator, 3);
//    try details.presentModes.resize(std.testing.allocator, 2);
//
//    try std.testing.expectEqual(@as(usize, 3), details.formats.items.len);
//    try std.testing.expectEqual(@as(usize, 2), details.presentModes.items.len);
//}
