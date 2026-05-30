const std = @import("std");

const c = @import("c.zig").c;
const math = @import("math.zig");
const Buffer = @import("Buffer.zig");
const Camera = @import("Camera.zig");
const Device = @import("Device.zig");
const FrameInfo = @import("FrameInfo.zig");
const KeyboardMovementController = @import("KeyboardMovementController.zig");
const Loop = @import("Loop.zig");
const Renderer = @import("Renderer.zig");
const SimpleRenderSystem = @import("SimpleRenderSystem.zig");
const Swapchain = @import("Swapchain.zig");
const Window = @import("Window.zig");
const Model = @import("Model.zig");
const GameObject = @import("GameObject.zig");
const checkSuccess = @import("utils.zig").checkSuccess;
const ArrayList = std.ArrayList;

/// Per-frame uniform data uploaded to the global UBO. Mirrors
/// `GlobalUbo` in `first_app.cpp`.
///
/// Stored as an `extern struct` so the field layout matches what GLSL
/// will see once a descriptor set lands in a later tutorial.
pub const GlobalUbo = extern struct {
    projectionView: math.Mat4 = math.identity_mat4,
    lightDirection: math.Vec3 = math.normalize3(.{ 1.0, -3.0, -1.0 }),
};

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
    // One host-visible UBO buffer per frame in flight, each holding a
    // single `GlobalUbo`. Mirrors the upstream tutorial bug-fix that
    // replaced the previous single-buffer-with-aligned-slices design:
    // when slices were packed into one allocation, the offsets used
    // by `vkFlushMappedMemoryRanges` had to satisfy both
    // `minUniformBufferOffsetAlignment` *and* `nonCoherentAtomSize`,
    // which is not generally true (and is flagged by the validation
    // layers on some drivers). Using one allocation per frame
    // sidesteps the problem because each allocation is independently
    // `nonCoherentAtomSize`-aligned and we always flush the whole
    // buffer.
    //
    // Each buffer is left persistently mapped via `map()` so per-frame
    // updates avoid the cost of repeatedly mapping/unmapping.
    var uboBuffers: [Swapchain.MAX_FRAMES_IN_FLIGHT]Buffer = undefined;
    var ubo_initialized: usize = 0;
    defer for (uboBuffers[0..ubo_initialized]) |*b| b.deinit();
    for (&uboBuffers) |*ub| {
        ub.* = try Buffer.init(
            self.device,
            @sizeOf(GlobalUbo),
            1,
            c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
            1,
        );
        ubo_initialized += 1;
        try ub.map(c.VK_WHOLE_SIZE, 0);
    }

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
            const frameIndex = self.renderer.getFrameIndex();
            var frameInfo: FrameInfo = .{
                .frameIndex = frameIndex,
                .frameTime = frameTime,
                .commandBuffer = commandBuffer,
                .camera = &camera,
            };

            // update: write into this frame's dedicated UBO buffer
            var ubo: GlobalUbo = .{
                .projectionView = math.mul4(camera.getProjection(), camera.getView()),
            };
            uboBuffers[frameIndex].writeToBuffer(@ptrCast(&ubo), c.VK_WHOLE_SIZE, 0);
            // The UBO buffer is HOST_VISIBLE but not HOST_COHERENT, so
            // an explicit flush is required to make the host write
            // visible to the device.
            try uboBuffers[frameIndex].flush(c.VK_WHOLE_SIZE, 0);

            // render
            self.renderer.beginSwapChainRenderPass(commandBuffer);
            try simpleRenderSystem.renderGameObjects(&frameInfo, self.gameObjects.items);
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
    // The `.obj` assets are embedded at build time by `embedAllModels`
    // in `build.zig` (the asset key is each file's basename under
    // `models/`).
    {
        const obj_bytes = @embedFile("flat_vase.obj");
        var model = try Model.createModelFromFile(self.device, self.alloc, obj_bytes);
        errdefer model.deinit();

        const flatVase = try GameObject.init(
            model,
            .{ 0, 0, 0 },
            .{
                .translation = .{ -0.5, 0.5, 2.5 },
                .scale = .{ 3.0, 1.5, 3.0 },
            },
        );
        try self.gameObjects.append(self.alloc, flatVase);
    }

    {
        const obj_bytes = @embedFile("smooth_vase.obj");
        var model = try Model.createModelFromFile(self.device, self.alloc, obj_bytes);
        errdefer model.deinit();

        const smoothVase = try GameObject.init(
            model,
            .{ 0, 0, 0 },
            .{
                .translation = .{ 0.5, 0.5, 2.5 },
                .scale = .{ 3.0, 1.5, 3.0 },
            },
        );
        try self.gameObjects.append(self.alloc, smoothVase);
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
