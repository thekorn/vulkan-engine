const std = @import("std");

const c = @import("c.zig").c;
const math = @import("math.zig");
const Buffer = @import("Buffer.zig");
const Camera = @import("Camera.zig");
const DebugUi = @import("DebugUi.zig");
const Descriptors = @import("Descriptors.zig");
const Device = @import("Device.zig");
const FrameInfo = @import("FrameInfo.zig");
const KeyboardMovementController = @import("KeyboardMovementController.zig");
const Loop = @import("Loop.zig");
const PointLightSystem = @import("systems/PointLightSystem.zig");
const Renderer = @import("Renderer.zig");
const SimpleRenderSystem = @import("systems/SimpleRenderSystem.zig");
const Swapchain = @import("Swapchain.zig");
const Window = @import("Window.zig");
const Model = @import("Model.zig");
const GameObject = @import("GameObject.zig");

/// Per-frame uniform data uploaded to the global UBO. Re-exported
/// from `FrameInfo` (mirrors the upstream tutorial 25 move of
/// `GlobalUbo` out of `first_app.cpp` and into `lve_frame_info.hpp`
/// so render systems can mutate it from their `update()` calls).
pub const GlobalUbo = FrameInfo.GlobalUbo;

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
/// Pool used to allocate the per-frame global descriptor sets in
/// `run()`. Sized for one uniform-buffer descriptor per frame in
/// flight. Owned by `FirstApp` so its lifetime spans every
/// `SimpleRenderSystem` rebuild triggered by swapchain recreation.
globalPool: Descriptors.DescriptorPool,
gameObjects: GameObject.Map,

pub fn init(alloc: std.mem.Allocator) !Self {
    const window = try Window.init(alloc, width, height);
    errdefer window.deinit();

    const device = try Device.init(alloc, window);
    errdefer device.deinit();

    var loop = try Loop.init(window);
    errdefer loop.deinit();

    var renderer = try Renderer.init(alloc, window, device);
    errdefer renderer.deinit();

    var poolBuilder = Descriptors.DescriptorPool.Builder.init(alloc, device);
    errdefer poolBuilder.deinit();
    poolBuilder.setMaxSets(Swapchain.MAX_FRAMES_IN_FLIGHT);
    try poolBuilder.addPoolSize(
        c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        Swapchain.MAX_FRAMES_IN_FLIGHT,
    );
    var globalPool = try poolBuilder.build();
    errdefer globalPool.deinit();

    var self: Self = .{
        .alloc = alloc,
        .window = window,
        .device = device,
        .loop = loop,
        .renderer = renderer,
        .globalPool = globalPool,
        .gameObjects = .empty,
    };

    try self.loadGameObjects();

    return self;
}

pub fn deinit(self: *Self) void {
    std.log.scoped(.firstApp).info("deinit first app", .{});
    var it = self.gameObjects.valueIterator();
    while (it.next()) |obj| obj.deinit();
    self.gameObjects.deinit(self.alloc);
    self.globalPool.deinit();
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

    // Global descriptor set layout: one uniform buffer at binding 0,
    // accessed from the vertex stage. Mirrors `globalSetLayout` in
    // the upstream tutorial's `FirstApp::run()`.
    var globalSetLayoutBuilder = Descriptors.DescriptorSetLayout.Builder.init(
        self.alloc,
        self.device,
    );
    errdefer globalSetLayoutBuilder.deinit();
    // Stage flags widened to `VK_SHADER_STAGE_ALL_GRAPHICS` because
    // the fragment shader now reads the global UBO too (it took over
    // the lighting calculation from the vertex shader).
    try globalSetLayoutBuilder.addBinding(
        0,
        c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        c.VK_SHADER_STAGE_ALL_GRAPHICS,
        1,
    );
    var globalSetLayout = try globalSetLayoutBuilder.build();
    defer globalSetLayout.deinit();

    // One descriptor set per frame in flight, each pointing at the
    // matching `uboBuffers[i]`. The `bufferInfos` array must outlive
    // the `DescriptorWriter` calls below — `writeBuffer` stores the
    // pointer, not a copy.
    var globalDescriptorSets: [Swapchain.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet = undefined;
    var bufferInfos: [Swapchain.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
    for (&globalDescriptorSets, 0..) |*set, i| {
        bufferInfos[i] = uboBuffers[i].descriptorInfo(c.VK_WHOLE_SIZE, 0);
        var writer = Descriptors.DescriptorWriter.init(
            self.alloc,
            &globalSetLayout,
            &self.globalPool,
        );
        defer writer.deinit();
        try writer.writeBuffer(0, &bufferInfos[i]);
        if (!try writer.build(set)) return error.DescriptorAllocationFailed;
    }

    var simpleRenderSystem = try SimpleRenderSystem.init(
        self.alloc,
        self.device,
        self.renderer.getSwapChainRenderPass(),
        globalSetLayout.getDescriptorSetLayout(),
    );
    defer simpleRenderSystem.deinit();

    var pointLightSystem = try PointLightSystem.init(
        self.alloc,
        self.device,
        self.renderer.getSwapChainRenderPass(),
        globalSetLayout.getDescriptorSetLayout(),
    );
    defer pointLightSystem.deinit();

    // Dear ImGui debug overlay. Built against the same swapchain
    // render pass as the rest of the scene, so its draw calls slot
    // into the existing render-pass scope after the point-light
    // billboards (matching the order the upstream Little Vulkan
    // Engine tutorial uses for its ImGui sample).
    var debugUi = try DebugUi.init(
        self.alloc,
        self.device,
        self.window,
        self.renderer.getSwapChainRenderPass(),
        @intCast(self.renderer.swapChain.?.swapChainImages.len),
    );
    defer debugUi.deinit();

    var camera: Camera = .{};

    var viewerObject = GameObject.createGameObject();
    // Pull the camera back so the freshly-added scene (vases + floor at
    // the origin) is in view before the user starts moving.
    viewerObject.transform.translation[2] = -2.5;
    var cameraController: KeyboardMovementController = .{};

    // Use the monotonic clock from GLFW — seconds (as f64) since
    // `glfwInit` — to compute per-frame delta time. This avoids
    // depending on the `std.time` clock APIs that were reworked in Zig
    // 0.16.
    var currentTime: f64 = c.glfwGetTime();

    // Scratch buffer for `DebugUi.text` lines; one allocation reused
    // across every frame to avoid per-frame heap traffic.
    var debugText: [256]u8 = undefined;

    while (self.loop.is_running()) {
        c.glfwPollEvents();

        const newTime: f64 = c.glfwGetTime();
        const frameTime: f32 = @floatCast(newTime - currentTime);
        currentTime = newTime;

        // Build this frame's ImGui draw data *before* recording any
        // Vulkan commands. The matching `debugUi.render(cb)` call
        // below replays the draw data into the swapchain render pass.
        debugUi.beginFrame();
        {
            _ = c.igBegin("Debug", null, 0);
            debugUi.text(&debugText, "frame time: {d:.2} ms", .{frameTime * 1000.0});
            debugUi.text(&debugText, "fps: {d:.1}", .{1.0 / frameTime});
            debugUi.text(&debugText, "frame index: {d}", .{self.renderer.currentFrameIndex});
            debugUi.text(&debugText, "objects: {d}", .{self.gameObjects.count()});
            debugUi.text(&debugText, "point lights: {d}", .{countPointLights(&self.gameObjects)});
            const camPos = viewerObject.transform.translation;
            debugUi.text(
                &debugText,
                "camera: ({d:.2}, {d:.2}, {d:.2})",
                .{ camPos[0], camPos[1], camPos[2] },
            );
            c.igEnd();
        }

        // Mouse-look first: pressing/holding the left mouse button
        // (outside of any ImGui window) rotates the camera. Calling
        // it before the keyboard pass lets `W` / `S` move along the
        // direction the user just looked, matching FPS conventions.
        cameraController.lookWithMouse(self.window.instance, &viewerObject);
        cameraController.moveInPlaneXZ(self.window.instance, frameTime, &viewerObject);
        camera.setViewYXZ(viewerObject.transform.translation, viewerObject.transform.rotation);

        const aspect = self.renderer.getAspectRatio();
        // camera.setOrthographicProjection(-aspect, aspect, -1, 1, -1, 1);
        camera.setPerspectiveProjection(std.math.degreesToRadians(50.0), aspect, 0.1, 100.0);

        const beginResult = self.renderer.beginFrame() catch |err| switch (err) {
            // If the swapchain had to be recreated and the formats
            // changed under us, our pipelines / render-systems were
            // built against the old render pass and are now invalid.
            // Tear them down and rebuild them against the new render
            // pass, then skip this frame.
            error.SwapChainFormatChanged => {
                simpleRenderSystem.deinit();
                simpleRenderSystem = try SimpleRenderSystem.init(
                    self.alloc,
                    self.device,
                    self.renderer.getSwapChainRenderPass(),
                    globalSetLayout.getDescriptorSetLayout(),
                );
                pointLightSystem.deinit();
                pointLightSystem = try PointLightSystem.init(
                    self.alloc,
                    self.device,
                    self.renderer.getSwapChainRenderPass(),
                    globalSetLayout.getDescriptorSetLayout(),
                );
                // The ImGui Vulkan backend keeps a pipeline bound to
                // the old (now-destroyed) render pass too — rebuild
                // it against the new one so the next
                // `debugUi.render(cb)` doesn't reference freed
                // Vulkan objects.
                try debugUi.recreate(self.renderer.getSwapChainRenderPass());
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
                .globalDescriptorSet = globalDescriptorSets[frameIndex],
                .gameObjects = &self.gameObjects,
            };

            // update: write into this frame's dedicated UBO buffer.
            // Projection and view are now stored separately so the
            // point-light vertex shader can extract the camera basis
            // from `view` to build a camera-facing billboard.
            // `pointLightSystem.update` then fills in `pointLights[]`
            // + `numLights` from the scene's point-light game objects.
            var ubo: GlobalUbo = .{
                .projection = camera.getProjection(),
                .view = camera.getView(),
                .inverseView = camera.getInverseView(),
            };
            pointLightSystem.update(&frameInfo, &ubo);
            uboBuffers[frameIndex].writeToBuffer(@ptrCast(&ubo), c.VK_WHOLE_SIZE, 0);
            // The UBO buffer is HOST_VISIBLE but not HOST_COHERENT, so
            // an explicit flush is required to make the host write
            // visible to the device.
            try uboBuffers[frameIndex].flush(c.VK_WHOLE_SIZE, 0);

            // render
            self.renderer.beginSwapChainRenderPass(commandBuffer);
            try simpleRenderSystem.renderGameObjects(&frameInfo);
            pointLightSystem.render(&frameInfo);
            // ImGui must be the *last* thing recorded inside the swap-
            // chain render pass so its draw commands composite on top
            // of the rendered scene (including the alpha-blended
            // point-light billboards).
            debugUi.render(commandBuffer);
            self.renderer.endSwapChainRenderPass(commandBuffer);
            self.renderer.endFrame() catch |err| switch (err) {
                error.SwapChainFormatChanged => {
                    simpleRenderSystem.deinit();
                    simpleRenderSystem = try SimpleRenderSystem.init(
                        self.alloc,
                        self.device,
                        self.renderer.getSwapChainRenderPass(),
                        globalSetLayout.getDescriptorSetLayout(),
                    );
                    pointLightSystem.deinit();
                    pointLightSystem = try PointLightSystem.init(
                        self.alloc,
                        self.device,
                        self.renderer.getSwapChainRenderPass(),
                        globalSetLayout.getDescriptorSetLayout(),
                    );
                    // Same swapchain-format-change handling as on
                    // `beginFrame` above — the ImGui pipeline needs
                    // to be rebuilt against the new render pass.
                    try debugUi.recreate(self.renderer.getSwapChainRenderPass());
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
                .translation = .{ -0.5, 0.5, 0.0 },
                .scale = .{ 3.0, 1.5, 3.0 },
            },
        );
        try self.gameObjects.put(self.alloc, flatVase.getId(), flatVase);
    }

    {
        const obj_bytes = @embedFile("smooth_vase.obj");
        var model = try Model.createModelFromFile(self.device, self.alloc, obj_bytes);
        errdefer model.deinit();

        const smoothVase = try GameObject.init(
            model,
            .{ 0, 0, 0 },
            .{
                .translation = .{ 0.5, 0.5, 0.0 },
                .scale = .{ 3.0, 1.5, 3.0 },
            },
        );
        try self.gameObjects.put(self.alloc, smoothVase.getId(), smoothVase);
    }

    {
        // Flat quad acting as the floor underneath the two vases. The
        // underlying model normal is `(0, -1, 0)`, which combined with
        // each point light's position produces the soft diffuse
        // highlight on the upward-facing side.
        const obj_bytes = @embedFile("quad.obj");
        var model = try Model.createModelFromFile(self.device, self.alloc, obj_bytes);
        errdefer model.deinit();

        const floor = try GameObject.init(
            model,
            .{ 0, 0, 0 },
            .{
                .translation = .{ 0.0, 0.5, 0.0 },
                .scale = .{ 3.0, 1.0, 3.0 },
            },
        );
        try self.gameObjects.put(self.alloc, floor.getId(), floor);
    }

    // Six colored point lights arranged in a circle around the
    // origin. Mirrors the upstream tutorial 25 scene: each light's
    // initial position is `(-1, -1, -1)` rotated around the world's
    // Y axis by `i * 2π / N`. `PointLightSystem.update` then spins
    // them around the same axis once per frame.
    const lightColors = [_]math.Vec3{
        .{ 1.0, 0.1, 0.1 },
        .{ 0.1, 0.1, 1.0 },
        .{ 0.1, 1.0, 0.1 },
        .{ 1.0, 1.0, 0.1 },
        .{ 0.1, 1.0, 1.0 },
        .{ 1.0, 1.0, 1.0 },
    };
    for (lightColors, 0..) |color, i| {
        var pointLight = GameObject.makePointLight(0.2, 0.1, .{ 1, 1, 1 });
        pointLight.color = color;

        // Rotation around axis (0, -1, 0): the upstream tutorial uses
        // `glm::rotate(mat4(1), i * 2π / N, {0, -1, 0}) * vec4(-1, -1, -1, 1)`.
        // For that axis the rotation matrix is
        //   [[ cos, 0, -sin],
        //    [   0, 1,    0],
        //    [ sin, 0,  cos]],
        // applied to `(-1, -1, -1)`.
        const angle: f32 = @as(f32, @floatFromInt(i)) *
            (2.0 * std.math.pi) / @as(f32, @floatFromInt(lightColors.len));
        const cosA = std.math.cos(angle);
        const sinA = std.math.sin(angle);
        const x = -1.0;
        const y: f32 = -1.0;
        const z = -1.0;
        pointLight.transform.translation = .{
            cosA * x - sinA * z,
            y,
            sinA * x + cosA * z,
        };

        try self.gameObjects.put(self.alloc, pointLight.getId(), pointLight);
    }
}

/// Count how many entries in `objects` carry a `PointLightComponent`.
/// Used by the debug overlay to surface the active light count
/// without having to peek at `GlobalUbo.numLights` (which is filled
/// in by `PointLightSystem.update` *after* the overlay is built).
fn countPointLights(objects: *const GameObject.Map) usize {
    var n: usize = 0;
    var it = objects.valueIterator();
    while (it.next()) |obj| if (obj.pointLight != null) {
        n += 1;
    };
    return n;
}

test "FirstApp default window dimensions are 800x600" {
    try std.testing.expectEqual(@as(comptime_int, 800), width);
    try std.testing.expectEqual(@as(comptime_int, 600), height);
}

test "FirstApp has expected fields and types" {
    const fields = @typeInfo(Self).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 7), fields.len);
    try std.testing.expectEqual(std.mem.Allocator, @FieldType(Self, "alloc"));
    try std.testing.expectEqual(*Window, @FieldType(Self, "window"));
    try std.testing.expectEqual(*Device, @FieldType(Self, "device"));
    try std.testing.expectEqual(Loop, @FieldType(Self, "loop"));
    try std.testing.expectEqual(Renderer, @FieldType(Self, "renderer"));
    try std.testing.expectEqual(Descriptors.DescriptorPool, @FieldType(Self, "globalPool"));
    try std.testing.expectEqual(GameObject.Map, @FieldType(Self, "gameObjects"));
}
