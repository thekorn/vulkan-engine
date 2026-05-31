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
const Texture = @import("Texture.zig");

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
/// Pool used to allocate the per-frame global descriptor sets *and*
/// the per-game-object material descriptor sets in `run()`. Sized
/// for one uniform-buffer descriptor per frame in flight plus
/// `2 * MAX_TEXTURE_SETS` combined-image-sampler descriptors (two
/// per material set: binding 0 diffuse + binding 1 normal map).
/// Owned by `FirstApp` so its lifetime spans every render-system
/// rebuild triggered by swapchain recreation.
globalPool: Descriptors.DescriptorPool,
gameObjects: GameObject.Map,
/// Heap-allocated `Texture` registry keyed by `@embedFile` basename
/// (e.g. `"stonefloor01_color_rgba.ktx"`,
/// `"stonefloor01_normal_rgba.ktx"`), plus two synthetic fallbacks:
/// `"__default_white__"` (1×1 RGBA8 white) for objects without a
/// `textureName` and `"__default_flat_normal__"` (1×1 RGBA8
/// (128, 128, 255)) for objects without a `normalName`. Stored as
/// pointers so the addresses remain stable as the map grows.
/// Populated by `loadTextures` from `init`; torn down in `deinit`.
textures: std.StringHashMapUnmanaged(*Texture),

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
    // Per-frame UBO sets plus one material descriptor set per
    // renderable game object. Each material set now binds **two**
    // combined-image-samplers (`binding = 0` diffuse,
    // `binding = 1` normal map), so the descriptor count for the
    // sampler pool is `2 * MAX_TEXTURE_SETS`.
    poolBuilder.setMaxSets(Swapchain.MAX_FRAMES_IN_FLIGHT + MAX_TEXTURE_SETS);
    try poolBuilder.addPoolSize(
        c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        Swapchain.MAX_FRAMES_IN_FLIGHT,
    );
    try poolBuilder.addPoolSize(
        c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        2 * MAX_TEXTURE_SETS,
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
        .textures = .empty,
    };

    try self.loadTextures();
    errdefer self.deinitTextures();

    try self.loadGameObjects();

    return self;
}

/// Upper bound on the number of per-game-object material descriptor
/// sets the `globalPool` is sized for. Each set holds two
/// combined-image-sampler descriptors (diffuse + normal map), so the
/// pool's `COMBINED_IMAGE_SAMPLER` count is `2 * MAX_TEXTURE_SETS`.
const MAX_TEXTURE_SETS: u32 = 8;

pub fn deinit(self: *Self) void {
    std.log.scoped(.firstApp).info("deinit first app", .{});
    var it = self.gameObjects.valueIterator();
    while (it.next()) |obj| obj.deinit();
    self.gameObjects.deinit(self.alloc);
    self.deinitTextures();
    self.globalPool.deinit();
    self.renderer.deinit();
    self.loop.deinit();
    self.device.deinit();
    self.window.deinit();
}

/// Deinit + free every `*Texture` in `self.textures` and release the
/// map's backing storage. Split out so the `errdefer` in `init` can
/// run independently of `deinit` after partial construction.
fn deinitTextures(self: *Self) void {
    var it = self.textures.valueIterator();
    while (it.next()) |tex_ptr| {
        tex_ptr.*.deinit();
        self.alloc.destroy(tex_ptr.*);
    }
    self.textures.deinit(self.alloc);
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

    // Per-object material descriptor set layout: two
    // combined-image-samplers in the fragment stage, bound at
    // `set = 1` by `SimpleRenderSystem`:
    //   binding 0 → diffuse (`diffuseMap` in `shader.frag`)
    //   binding 1 → tangent-space normal map (`normalMap`)
    // Built once and shared across every per-material descriptor set
    // allocated below.
    var textureSetLayoutBuilder = Descriptors.DescriptorSetLayout.Builder.init(
        self.alloc,
        self.device,
    );
    errdefer textureSetLayoutBuilder.deinit();
    try textureSetLayoutBuilder.addBinding(
        0,
        c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        c.VK_SHADER_STAGE_FRAGMENT_BIT,
        1,
    );
    try textureSetLayoutBuilder.addBinding(
        1,
        c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        c.VK_SHADER_STAGE_FRAGMENT_BIT,
        1,
    );
    var textureSetLayout = try textureSetLayoutBuilder.build();
    defer textureSetLayout.deinit();

    // One descriptor set per renderable `GameObject`, each with both
    // a diffuse and a normal map. Objects without a named diffuse
    // (`textureName`) get the 1×1 white fallback; objects without a
    // named normal map (`normalName`) get the 1×1 flat-normal
    // fallback (RGB = (128, 128, 255), decoding to the tangent-space
    // `+Z` unit vector). This means the shader path is uniform for
    // every renderable, materials without a normal map fall back to
    // the geometric normal in `shader.frag`, and we only need one
    // descriptor set per object instead of cross-referencing two
    // texture maps at draw time.
    //
    // The two `VkDescriptorImageInfo`s for each object live on the
    // current iteration's stack frame; `DescriptorWriter.build`
    // forwards their addresses to `vkUpdateDescriptorSets`
    // immediately and never touches them again, so the per-iteration
    // lifetime is enough.
    var stamp_it = self.gameObjects.valueIterator();
    while (stamp_it.next()) |obj| {
        if (obj.model == null) continue;

        const diffuse_name = obj.textureName orelse "__default_white__";
        const normal_name = obj.normalName orelse "__default_flat_normal__";
        const diffuse_tex = self.textures.get(diffuse_name) orelse
            return error.MissingTexture;
        const normal_tex = self.textures.get(normal_name) orelse
            return error.MissingTexture;

        const diffuse_info = diffuse_tex.descriptorInfo();
        const normal_info = normal_tex.descriptorInfo();

        var writer = Descriptors.DescriptorWriter.init(
            self.alloc,
            &textureSetLayout,
            &self.globalPool,
        );
        defer writer.deinit();
        try writer.writeImage(0, &diffuse_info);
        try writer.writeImage(1, &normal_info);

        // SAFETY: written by writer.build below before any read.
        var set: c.VkDescriptorSet = undefined;
        if (!try writer.build(&set)) return error.DescriptorAllocationFailed;
        obj.textureDescriptorSet = set;
    }

    var simpleRenderSystem = try SimpleRenderSystem.init(
        self.alloc,
        self.device,
        self.renderer.getSwapChainRenderPass(),
        globalSetLayout.getDescriptorSetLayout(),
        textureSetLayout.getDescriptorSetLayout(),
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
                    textureSetLayout.getDescriptorSetLayout(),
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
                        textureSetLayout.getDescriptorSetLayout(),
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

/// Populate `self.textures` with every `Texture` the scene needs:
/// the embedded KTX1 stone-floor diffuse + normal maps, plus two
/// synthetic 1×1 fallbacks (a white diffuse and a flat normal map)
/// used by every object that does not opt in to a named texture.
/// Mirrors the upstream tutorial's `LveTexture`-loading step in
/// `FirstApp::loadGameObjects`.
fn loadTextures(self: *Self) !void {
    // Roll back the registry on a partial failure: any texture that
    // already made it into `self.textures` (plus the map's backing
    // allocation) needs to be torn down before this function returns
    // an error, otherwise `init`'s `errdefer self.deinitTextures()`
    // never fires (it's only registered *after* `loadTextures`
    // succeeds).
    errdefer self.deinitTextures();

    // 1×1 white diffuse fallback. The fragment shader multiplies the
    // sampled RGB into the final color, so (1, 1, 1, 1) leaves the
    // look of untextured objects unchanged.
    {
        const tex = try self.alloc.create(Texture);
        errdefer self.alloc.destroy(tex);
        const white = [_]u8{ 255, 255, 255, 255 };
        tex.* = try Texture.initFromPixels(self.device, white[0..], 1, 1);
        errdefer tex.deinit();
        try self.textures.put(self.alloc, "__default_white__", tex);
    }

    // 1×1 flat-normal fallback. RGB (128, 128, 255) decodes to the
    // tangent-space `+Z` unit vector — i.e. "no perturbation" — so
    // objects without an explicit normal map still take the same
    // codepath in `shader.frag` but come out indistinguishable from
    // the pre-normal-mapping look.
    {
        const tex = try self.alloc.create(Texture);
        errdefer self.alloc.destroy(tex);
        const flat = [_]u8{ 128, 128, 255, 255 };
        tex.* = try Texture.initFromPixels(self.device, flat[0..], 1, 1);
        errdefer tex.deinit();
        try self.textures.put(self.alloc, "__default_flat_normal__", tex);
    }

    // Stone-floor color map. Embedded at build time by
    // `embedAllTextures` (`build.zig`) and parsed as KTX1 by
    // `Texture.initFromKtxBytes` (mip 0 only for now).
    {
        const tex = try self.alloc.create(Texture);
        errdefer self.alloc.destroy(tex);
        const ktx_bytes = @embedFile("stonefloor01_color_rgba.ktx");
        tex.* = try Texture.initFromKtxBytes(self.device, ktx_bytes);
        errdefer tex.deinit();
        try self.textures.put(self.alloc, "stonefloor01_color_rgba.ktx", tex);
    }

    // Matching tangent-space normal map for the stone floor. Same
    // loader path as the diffuse — the KTX1 file ships as RGBA8 so
    // it satisfies `initFromKtxBytes`'s strict format checks.
    {
        const tex = try self.alloc.create(Texture);
        errdefer self.alloc.destroy(tex);
        const ktx_bytes = @embedFile("stonefloor01_normal_rgba.ktx");
        tex.* = try Texture.initFromKtxBytes(self.device, ktx_bytes);
        errdefer tex.deinit();
        try self.textures.put(self.alloc, "stonefloor01_normal_rgba.ktx", tex);
    }
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

        var floor = try GameObject.init(
            model,
            .{ 0, 0, 0 },
            .{
                .translation = .{ 0.0, 0.5, 0.0 },
                .scale = .{ 3.0, 1.0, 3.0 },
            },
        );
        // Tag the floor with the embedded KTX texture keys (diffuse
        // + matching tangent-space normal map). `run()` looks each
        // texture up in `self.textures` after the descriptor sets
        // have been built and stamps the matching
        // `textureDescriptorSet` onto each object. `GameObject.color`
        // is unused by `SimpleRenderSystem`; the per-vertex color
        // (white, supplied as the OBJ default by tinyobjloader) is
        // what the fragment shader multiplies the sampled texel by.
        floor.textureName = "stonefloor01_color_rgba.ktx";
        floor.normalName = "stonefloor01_normal_rgba.ktx";
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
    try std.testing.expectEqual(@as(usize, 8), fields.len);
    try std.testing.expectEqual(std.mem.Allocator, @FieldType(Self, "alloc"));
    try std.testing.expectEqual(*Window, @FieldType(Self, "window"));
    try std.testing.expectEqual(*Device, @FieldType(Self, "device"));
    try std.testing.expectEqual(Loop, @FieldType(Self, "loop"));
    try std.testing.expectEqual(Renderer, @FieldType(Self, "renderer"));
    try std.testing.expectEqual(Descriptors.DescriptorPool, @FieldType(Self, "globalPool"));
    try std.testing.expectEqual(GameObject.Map, @FieldType(Self, "gameObjects"));
    try std.testing.expectEqual(
        std.StringHashMapUnmanaged(*Texture),
        @FieldType(Self, "textures"),
    );
}
