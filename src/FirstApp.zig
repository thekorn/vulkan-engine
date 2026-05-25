const std = @import("std");

const c = @import("c.zig").c;
const cglm = @import("c.zig").cglm;
const Device = @import("Device.zig");
const Loop = @import("Loop.zig");
const Renderer = @import("Renderer.zig");
const SimpleRenderSystem = @import("SimpleRenderSystem.zig");
const Window = @import("Window.zig");
const Model = @import("Model.zig");
const GameObject = @import("GameObject.zig");
const checkSuccess = @import("utils.zig").checkSuccess;
const ArrayList = std.ArrayList;

const Self = @This();

pub const width = 800;
pub const height = 600;

alloc: std.mem.Allocator,
// `window` and `device` are stored as pointers because their `init`
// functions heap-allocate `Self` and own their own lifetime via
// `alloc.destroy(self)` in `deinit`. Holding them as stable pointers also
// guarantees that the back-pointers stored in sub-components (Device,
// Loop, Renderer, Model) stay valid when `Self` is returned by value
// from this `init` and copied into the caller's storage.
window: *Window,
device: *Device,
loop: Loop,
renderer: Renderer,
gameObjects: ArrayList(GameObject),

pub fn init(alloc: std.mem.Allocator) !Self {
    const window = try Window.init(alloc, width, height);
    errdefer window.deinit();

    const device = try Device.init(alloc, window);
    errdefer device.deinit();

    var loop = try Loop.init(window);
    errdefer loop.deinit();

    var renderer = try Renderer.init(alloc, window, device);
    errdefer renderer.deinit();

    var self: Self = .{
        .alloc = alloc,
        .window = window,
        .device = device,
        .loop = loop,
        .renderer = renderer,
        .gameObjects = .empty,
    };

    try self.loadGameObjects();

    return self;
}

pub fn deinit(self: *Self) void {
    std.log.scoped(.firstApp).info("deinit first app", .{});
    for (self.gameObjects.items) |*obj| obj.deinit();
    self.gameObjects.deinit(self.alloc);
    self.renderer.deinit();
    self.loop.deinit();
    self.device.deinit();
    self.window.deinit();
}

pub fn run(self: *Self) !void {
    var simpleRenderSystem = try SimpleRenderSystem.init(
        self.alloc,
        self.device,
        self.renderer.getSwapChainRenderPass(),
    );
    defer simpleRenderSystem.deinit();

    while (self.loop.is_running()) {
        c.glfwPollEvents();

        const beginResult = self.renderer.beginFrame() catch |err| switch (err) {
            // If the swapchain had to be recreated and the formats
            // changed under us, our pipeline / render-system was built
            // against the old render pass and is now invalid. Tear it
            // down and rebuild it against the new render pass, then
            // skip this frame.
            error.SwapChainFormatChanged => {
                simpleRenderSystem.deinit();
                simpleRenderSystem = try SimpleRenderSystem.init(
                    self.alloc,
                    self.device,
                    self.renderer.getSwapChainRenderPass(),
                );
                continue;
            },
            else => return err,
        };

        if (beginResult) |commandBuffer| {
            self.renderer.beginSwapChainRenderPass(commandBuffer);
            try simpleRenderSystem.renderGameObjects(commandBuffer, self.gameObjects.items);
            self.renderer.endSwapChainRenderPass(commandBuffer);
            self.renderer.endFrame() catch |err| switch (err) {
                error.SwapChainFormatChanged => {
                    simpleRenderSystem.deinit();
                    simpleRenderSystem = try SimpleRenderSystem.init(
                        self.alloc,
                        self.device,
                        self.renderer.getSwapChainRenderPass(),
                    );
                    continue;
                },
                else => return err,
            };
        }
    }

    // Wait for the device to become idle so the GPU isn't using any of
    // the resources we're about to tear down. Without this, the
    // validation layers (rightfully) complain on shutdown.
    _ = c.vkDeviceWaitIdle(self.device.globalDevice);
}

fn loadGameObjects(self: *Self) !void {
    const vertices = [_]Model.Vertex{
        Model.Vertex{ .position = .{ 0.0, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
        Model.Vertex{ .position = .{ 0.5, 0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
        Model.Vertex{ .position = .{ -0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
    };

    var colors = [_]cglm.vec3{
        .{ 1.0, 0.7, 0.73 },
        .{ 1.0, 0.87, 0.73 },
        .{ 1.0, 1.0, 0.73 },
        .{ 0.73, 1.0, 0.8 },
        .{ 0.73, 0.88, 1.0 },
    };

    for (&colors) |*color| {
        color.* = .{
            @floatCast(cglm.pow(@as(f64, color[0]), 2.2)),
            @floatCast(cglm.pow(@as(f64, color[1]), 2.2)),
            @floatCast(cglm.pow(@as(f64, color[2]), 2.2)),
        };
    }

    for (0..40) |i| {
        // Each GameObject owns its Model (and therefore its VkBuffer /
        // VkDeviceMemory), so allocate a fresh Model per object rather
        // than copying one shared Model by value — copying would cause
        // every GameObject.deinit() to destroy the same Vulkan handles,
        // flooding the validation layer with errors on shutdown.
        var model = try Model.init(self.device, vertices[0..]);
        errdefer model.deinit();

        const triangle = try GameObject.init(
            model,
            colors[i % colors.len],
            .{
                .scale = .{ 2.0, 0.5 },
                .rotation = @as(f32, @floatFromInt(i)) * std.math.pi * 0.25,
            },
        );

        try self.gameObjects.append(self.alloc, triangle);
    }
}

test "FirstApp default window dimensions are 800x600" {
    try std.testing.expectEqual(@as(comptime_int, 800), width);
    try std.testing.expectEqual(@as(comptime_int, 600), height);
}

test "FirstApp has expected fields and types" {
    const fields = @typeInfo(Self).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 6), fields.len);
    try std.testing.expectEqual(std.mem.Allocator, @FieldType(Self, "alloc"));
    try std.testing.expectEqual(*Window, @FieldType(Self, "window"));
    try std.testing.expectEqual(*Device, @FieldType(Self, "device"));
    try std.testing.expectEqual(Loop, @FieldType(Self, "loop"));
    try std.testing.expectEqual(Renderer, @FieldType(Self, "renderer"));
    try std.testing.expectEqual(ArrayList(GameObject), @FieldType(Self, "gameObjects"));
}
