const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;

const Self = @This();
instance: c.VkInstance,

fn checkSuccess(result: c.VkResult) !void {
    switch (result) {
        c.VK_SUCCESS => {},
        else => return error.Unexpected,
    }
}

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

    const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
    const enabled_layers: []const [*:0]const u8 = if (enable_validation_layers) &validation_layers else &.{};

    const extensions = try getExtensionNames(alloc, enable_validation_layers);
    for (extensions) |ext| {
        std.debug.print("Extension: {s}\n", .{ext});
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
