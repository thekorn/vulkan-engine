const std = @import("std");
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

// Helper for tests: try to bring up a Window, but skip the test when the
// environment can't host one (e.g. headless CI without a display server).
fn initOrSkip(width: i32, height: i32) !Self {
    if (std.c.getenv("CI") != null) return error.SkipZigTest;

    return Self.init(width, height) catch |err| switch (err) {
        error.GlfwInitFailed, error.GlfwCreateWindowFailed => return error.SkipZigTest,
    };
}

test "Window has expected fields and types" {
    const info = @typeInfo(Self).@"struct";
    try std.testing.expectEqual(@as(usize, 3), info.fields.len);

    try std.testing.expectEqual(*c.GLFWwindow, @FieldType(Self, "instance"));
    try std.testing.expectEqual(i32, @FieldType(Self, "width"));
    try std.testing.expectEqual(i32, @FieldType(Self, "height"));
}

test "Window.init stores the requested dimensions" {
    var window = try initOrSkip(800, 600);
    defer window.deinit();

    try std.testing.expectEqual(@as(i32, 800), window.width);
    try std.testing.expectEqual(@as(i32, 600), window.height);
}

test "Window.init stores non-square dimensions" {
    var window = try initOrSkip(1280, 720);
    defer window.deinit();

    try std.testing.expectEqual(@as(i32, 1280), window.width);
    try std.testing.expectEqual(@as(i32, 720), window.height);
}

test "Window.init returns a non-null window handle" {
    var window = try initOrSkip(640, 480);
    defer window.deinit();

    // `instance` is a non-optional pointer; this just ensures the value is
    // a usable address (i.e. init did not silently hand us garbage).
    try std.testing.expect(@intFromPtr(window.instance) != 0);
}

test "Window.should_close is false for a freshly created window" {
    var window = try initOrSkip(320, 240);
    defer window.deinit();

    try std.testing.expect(!window.should_close());
}

test "Window.should_close becomes true after glfwSetWindowShouldClose" {
    var window = try initOrSkip(320, 240);
    defer window.deinit();

    c.glfwSetWindowShouldClose(window.instance, c.GLFW_TRUE);
    try std.testing.expect(window.should_close());
}
