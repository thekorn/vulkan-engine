const std = @import("std");
const builtin = @import("builtin");

const c = @import("c.zig").c;
const checkSuccess = @import("utils.zig").checkSuccess;

const Self = @This();
alloc: std.mem.Allocator,
instance: *c.GLFWwindow,
width: i32,
height: i32,
framebufferResized: bool = false,

pub fn init(alloc: std.mem.Allocator, width: i32, height: i32) !*Self {
    if (c.glfwInit() == 0) return error.GlfwInitFailed;
    errdefer c.glfwTerminate();

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_TRUE);

    const window = c.glfwCreateWindow(width, height, "Vulkan", null, null) orelse return error.GlfwCreateWindowFailed;
    errdefer c.glfwDestroyWindow(window);

    const self = try alloc.create(Self);
    self.* = .{
        .alloc = alloc,
        .instance = window,
        .width = width,
        .height = height,
    };

    c.glfwSetWindowUserPointer(window, @ptrCast(self));
    _ = c.glfwSetFramebufferSizeCallback(window, framebufferResizeCallback);

    return self;
}

pub fn deinit(self: *Self) void {
    c.glfwDestroyWindow(self.instance);
    c.glfwTerminate();
    self.alloc.destroy(self);
}

pub fn should_close(self: *Self) bool {
    return c.glfwWindowShouldClose(self.instance) != 0;
}

pub fn create_surface(self: *Self, instance: c.VkInstance, surface: *c.VkSurfaceKHR) !void {
    try checkSuccess(c.glfwCreateWindowSurface(instance, self.instance, null, surface));
}

pub fn getExtend(self: *Self) c.VkExtent2D {
    return .{
        .width = @intCast(self.width),
        .height = @intCast(self.height),
    };
}

pub fn wasWindowResized(self: *Self) bool {
    return self.framebufferResized;
}

pub fn resetWindowResized(self: *Self) void {
    self.framebufferResized = false;
}

fn framebufferResizeCallback(
    window: ?*c.GLFWwindow,
    width: c_int,
    height: c_int,
) callconv(.c) void {
    std.log.scoped(.window).info("calling window resize callback", .{});
    const ptr = c.glfwGetWindowUserPointer(window);
    const w: *Self = @ptrCast(@alignCast(ptr));
    w.framebufferResized = true;
    w.width = width;
    w.height = height;
}

// Helper for tests: try to bring up a Window, but skip the test when the
// skipping as it's currently broken on (headless) Linux
fn initOrSkip(alloc: std.mem.Allocator, width: i32, height: i32) !*Self {
    if (builtin.os.tag == .linux) return error.SkipZigTest;

    return Self.init(alloc, width, height) catch |err| switch (err) {
        error.GlfwInitFailed, error.GlfwCreateWindowFailed => return error.SkipZigTest,
        else => return err,
    };
}

test "Window has expected fields and types" {
    const info = @typeInfo(Self).@"struct";
    try std.testing.expectEqual(@as(usize, 5), info.fields.len);

    try std.testing.expectEqual(std.mem.Allocator, @FieldType(Self, "alloc"));
    try std.testing.expectEqual(*c.GLFWwindow, @FieldType(Self, "instance"));
    try std.testing.expectEqual(i32, @FieldType(Self, "width"));
    try std.testing.expectEqual(i32, @FieldType(Self, "height"));
    try std.testing.expectEqual(bool, @FieldType(Self, "framebufferResized"));
}

test "Window.init stores the requested dimensions" {
    const window = try initOrSkip(std.testing.allocator, 800, 600);
    defer window.deinit();

    try std.testing.expectEqual(@as(i32, 800), window.width);
    try std.testing.expectEqual(@as(i32, 600), window.height);
}

test "Window.init stores non-square dimensions" {
    const window = try initOrSkip(std.testing.allocator, 1280, 720);
    defer window.deinit();

    try std.testing.expectEqual(@as(i32, 1280), window.width);
    try std.testing.expectEqual(@as(i32, 720), window.height);
}

test "Window.init returns a non-null window handle" {
    const window = try initOrSkip(std.testing.allocator, 640, 480);
    defer window.deinit();

    // `instance` is a non-optional pointer; this just ensures the value is
    // a usable address (i.e. init did not silently hand us garbage).
    try std.testing.expect(@intFromPtr(window.instance) != 0);
}

test "Window.should_close is false for a freshly created window" {
    const window = try initOrSkip(std.testing.allocator, 320, 240);
    defer window.deinit();

    try std.testing.expect(!window.should_close());
}

test "Window.should_close becomes true after glfwSetWindowShouldClose" {
    const window = try initOrSkip(std.testing.allocator, 320, 240);
    defer window.deinit();

    c.glfwSetWindowShouldClose(window.instance, c.GLFW_TRUE);
    try std.testing.expect(window.should_close());
}
