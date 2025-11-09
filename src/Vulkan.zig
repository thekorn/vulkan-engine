const std = @import("std");
const buildin = @import("builtin");
const c = @import("c.zig").c;

const Self = @This();
instance: c.VkInstance,

fn checkSuccess(result: c.VkResult) !void {
    switch (result) {
        c.VK_SUCCESS => {},
        else => return error.Unexpected,
    }
}

fn getExtensionNames(alloc: std.mem.Allocator) ![][*c]const u8 {
    var glfwExtensionCount: u32 = 0;
    var glfwExtensions = c.glfwGetRequiredInstanceExtensions(&glfwExtensionCount);

    var extensions: std.ArrayList([*c]const u8) = .empty;
    errdefer extensions.deinit(alloc);

    // if this is NULLm the vvulklan is likely init before glfw - change order
    std.debug.assert(glfwExtensionCount > 0);
    for (glfwExtensions[0..glfwExtensionCount]) |ext| {
        try extensions.append(alloc, ext);
    }

    const extra_extensions = switch (buildin.os.tag) {
        // see: https://vulkan.lunarg.com/doc/sdk/1.3.283.0/mac/getting_started.html
        // section `Common Problems - Encountered VK_ERROR_INCOMPATIBLE_DRIVER`
        .ios, .macos, .tvos, .watchos => &[_][*]const u8{
            c.VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME,
            c.VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME,
        },
        else => &.{},
    };

    try extensions.appendSlice(alloc, extra_extensions);

    return extensions.toOwnedSlice(alloc);
}

pub fn init(alloc: std.mem.Allocator) !Self {
    var instance: c.VkInstance = undefined;

    const extensions = try getExtensionNames(alloc);
    for (extensions) |ext| {
        std.debug.print("{s}\n", .{ext});
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

    const info = c.VkInstanceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .flags = c.VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
        .enabledExtensionCount = @intCast(extensions.len),
        .ppEnabledExtensionNames = extensions.ptr,
        .pApplicationInfo = &appInfo,
        .enabledLayerCount = 0,
    };

    try checkSuccess(c.vkCreateInstance(&info, null, &instance));
    return .{
        .instance = instance,
    };
}

pub fn deinit(self: Self) void {
    c.vkDestroyInstance(self.instance, null);
}
