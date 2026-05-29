const std = @import("std");

const c = @import("c.zig").c;
const cglm = @import("c.zig").cglm;
const Camera = @import("Camera.zig");
const Device = @import("Device.zig");
const KeyboardMovementController = @import("KeyboardMovementController.zig");
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

    var camera: Camera = .{};

    var viewerObject = GameObject.createGameObject();
    const cameraController: KeyboardMovementController = .{};

    // Use the monotonic clock from GLFW — seconds (as f64) since
    // `glfwInit` — to compute per-frame delta time. This avoids
    // depending on the `std.time` clock APIs that were reworked in Zig
    // 0.16.
    var currentTime: f64 = c.glfwGetTime();

    while (self.loop.is_running()) {
        c.glfwPollEvents();

        const newTime: f64 = c.glfwGetTime();
        const frameTime: f32 = @floatCast(newTime - currentTime);
        currentTime = newTime;

        cameraController.moveInPlaneXZ(self.window.instance, frameTime, &viewerObject);
        camera.setViewYXZ(viewerObject.transform.translation, viewerObject.transform.rotation);

        const aspect = self.renderer.getAspectRatio();
        // camera.setOrthographicProjection(-aspect, aspect, -1, 1, -1, 1);
        camera.setPerspectiveProjection(std.math.degreesToRadians(50.0), aspect, 0.1, 10.0);

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
            try simpleRenderSystem.renderGameObjects(commandBuffer, self.gameObjects.items, &camera);
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

// temporary helper function, creates a 1x1x1 cube centered at offset
fn createCubeModel(device: *Device, offset: cglm.vec3) !Model {
    var vertices = [_]Model.Vertex{
        // left face (white)
        .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.9, 0.9, 0.9 } },
        .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.9, 0.9, 0.9 } },
        .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.9, 0.9, 0.9 } },
        .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.9, 0.9, 0.9 } },
        .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.9, 0.9, 0.9 } },
        .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.9, 0.9, 0.9 } },

        // right face (yellow)
        .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.8, 0.8, 0.1 } },
        .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.8, 0.8, 0.1 } },
        .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.8, 0.8, 0.1 } },
        .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.8, 0.8, 0.1 } },
        .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.8, 0.8, 0.1 } },
        .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.8, 0.8, 0.1 } },

        // top face (orange, remember y axis points down)
        .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.9, 0.6, 0.1 } },
        .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.9, 0.6, 0.1 } },
        .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.9, 0.6, 0.1 } },
        .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.9, 0.6, 0.1 } },
        .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.9, 0.6, 0.1 } },
        .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.9, 0.6, 0.1 } },

        // bottom face (red)
        .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.8, 0.1, 0.1 } },
        .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.8, 0.1, 0.1 } },
        .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.8, 0.1, 0.1 } },
        .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.8, 0.1, 0.1 } },
        .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.8, 0.1, 0.1 } },
        .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.8, 0.1, 0.1 } },

        // nose face (blue)
        .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.1, 0.1, 0.8 } },
        .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.1, 0.1, 0.8 } },
        .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.1, 0.1, 0.8 } },
        .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.1, 0.1, 0.8 } },
        .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.1, 0.1, 0.8 } },
        .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.1, 0.1, 0.8 } },

        // tail face (green)
        .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.1, 0.8, 0.1 } },
        .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.1, 0.8, 0.1 } },
        .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.1, 0.8, 0.1 } },
        .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.1, 0.8, 0.1 } },
        .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.1, 0.8, 0.1 } },
        .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.1, 0.8, 0.1 } },
    };

    for (&vertices) |*v| {
        v.position[0] += offset[0];
        v.position[1] += offset[1];
        v.position[2] += offset[2];
    }

    return Model.init(device, vertices[0..]);
}

fn loadGameObjects(self: *Self) !void {
    var model = try createCubeModel(self.device, .{ 0.0, 0.0, 0.0 });
    errdefer model.deinit();

    const cube = try GameObject.init(
        model,
        .{ 0, 0, 0 },
        .{
            .translation = .{ 0.0, 0.0, 2.5 },
            .scale = .{ 0.5, 0.5, 0.5 },
        },
    );

    try self.gameObjects.append(self.alloc, cube);
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
