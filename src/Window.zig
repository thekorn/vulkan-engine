const c = @import("c.zig").c;
const checkSuccess = @import("utils.zig").checkSuccess;

const Self = @This();
instance: *c.GLFWwindow,
width: i32,
height: i32,

pub fn init(width: i32, height: i32) !Self {
    if (c.glfwInit() == 0) return error.GlfwInitFailed;

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_FALSE);

    const window = c.glfwCreateWindow(width, height, "Vulkan", null, null) orelse return error.GlfwCreateWindowFailed;
    return .{
        .instance = window,
        .width = width,
        .height = height,
    };
}

pub fn deinit(self: *Self) void {
    c.glfwDestroyWindow(self.instance);
    c.glfwTerminate();
}

pub fn should_close(self: *Self) bool {
    return c.glfwWindowShouldClose(self.instance) != 0;
}

pub fn create_surface(self: *Self, instance: c.VkInstance, surface: *c.VkSurfaceKHR) !void {
    try checkSuccess(c.glfwCreateWindowSurface(instance, self.instance, null, surface));
}
