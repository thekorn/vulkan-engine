---
globs: ["src/**/*.zig", "src/**/*.h", "src/**/*.cpp"]
---

# Component Reference

Per-file descriptions for every module under `src/`. Loaded
automatically when editing Zig (or wrapper C/C++) sources. For the
big-picture data flow see [architecture.md](./architecture.md).

## `main.zig` — Entry Point

- **Purpose:** Construct the top-level application and run it.
- **Key Functions:**
  - `main()` - Creates a page allocator, initializes `FirstApp`, runs it
    and `defer`s `deinit`.
- All test imports for the test runner are also registered here.

## `FirstApp.zig` — Application Root

- **Purpose:** Owns the full application lifetime and the per-frame loop.
- **Window Size:** 800x600 (`FirstApp.width` / `FirstApp.height`)
- **Fields:**
  - `alloc` - Allocator passed in from `main`
  - `window: *Window`, `device: *Device` - heap-allocated, stable
    back-references for sub-components
  - `loop: Loop`, `renderer: Renderer`
  - `globalPool: Descriptors.DescriptorPool` - owned for the full
    application lifetime; sized for one uniform-buffer descriptor per
    frame in flight. Used by `run()` to allocate the per-frame global
    descriptor sets that point at the per-frame UBO buffers.
  - `gameObjects: GameObject.Map` (an
    `AutoHashMapUnmanaged(u64, GameObject)` keyed by `id_t`, matching
    the upstream `LveGameObject::Map`).
- **Types:**
  - `GlobalUbo` - `extern struct` mirroring the std140 layout the
    vertex shader expects at `set = 0, binding = 0`:
    `projectionView: Mat4`, `ambientLightColor: Vec4` (`xyz`=color,
    `w`=intensity), `lightPosition: Vec3` (point-light world-space
    position) and `lightColor: Vec4 align(16)` (`xyz`=color,
    `w`=intensity). Explicit `align(16)` mirrors the `alignas(16)`
    on the C++ side to guarantee the std140 offset of 96.
- **Key Functions:**
  - `init(alloc)` - Wires up window → device → loop → renderer, then calls
    `loadGameObjects()`.
  - `deinit()` - Tears everything down in reverse order.
  - `run()` - Main loop:
    1. Allocate one host-visible `Buffer` per frame in flight (an
       array of `MAX_FRAMES_IN_FLIGHT` single-instance UBO buffers)
       and `map()` each persistently. One buffer per frame is the
       upstream tutorial's bug-fix for `vkFlushMappedMemoryRanges`
       alignment: a single packed buffer would force its slice
       offsets to satisfy *both* `minUniformBufferOffsetAlignment`
       *and* `nonCoherentAtomSize`, which isn't generally true. Each
       independent allocation is `nonCoherentAtomSize`-aligned, and
       the per-frame buffer is always written and flushed in whole.
    2. Build a `globalSetLayout` (one `UNIFORM_BUFFER` binding at
       binding 0, `VK_SHADER_STAGE_ALL_GRAPHICS` because the fragment
       shader now reads the UBO too) via
       `Descriptors.DescriptorSetLayout.Builder`, then allocate one
       `globalDescriptorSets[i]` per frame in flight out of
       `self.globalPool`, each pointing at the matching `uboBuffers[i]`
       via `Descriptors.DescriptorWriter`.
    3. Build a `SimpleRenderSystem` (passing `globalSetLayout`), a
       `Camera`, a model-less `viewerObject` (via
       `GameObject.createGameObject`) and a `KeyboardMovementController`.
    4. Poll GLFW events.
    5. Compute `frameTime` (seconds) from `glfwGetTime()`.
    6. `cameraController.moveInPlaneXZ(...)` updates the viewer
       object's transform from keyboard input.
    7. `camera.setViewYXZ(...)` syncs the camera to the viewer
       object's translation/rotation, then `setPerspectiveProjection`
       updates the projection.
    8. `renderer.beginFrame()` → build a `FrameInfo` for the current
       frame (including `globalDescriptorSets[frameIndex]` and a
       pointer to `self.gameObjects`) → write `projectionView` into
       the current frame's UBO buffer via
       `writeToBuffer(VK_WHOLE_SIZE)` + `flush(VK_WHOLE_SIZE)` →
       `beginSwapChainRenderPass` →
       `simpleRenderSystem.renderGameObjects(&frameInfo)` (which
       binds the global descriptor set once and then iterates
       `frameInfo.gameObjects.valueIterator()`, issuing a draw per
       `GameObject` with just the model + normal matrices as push
       constants) → `endSwapChainRenderPass` → `endFrame`.
    9. If the swapchain has to be recreated and reports
       `error.SwapChainFormatChanged`, the render system is rebuilt
       against the new render pass and the frame is skipped.
    10. `vkDeviceWaitIdle` before returning so the GPU is finished with
        everything before resources are destroyed.
  - `loadGameObjects()` - Loads the embedded `flat_vase.obj`,
    `smooth_vase.obj` and `quad.obj` via `Model.createModelFromFile`
    and inserts each `GameObject` into `self.gameObjects` keyed by
    its `getId()`:
    - flat vase at `{-0.5, 0.5, 0.0}`, scale `{3, 1.5, 3}`
    - smooth vase at `{0.5, 0.5, 0.0}`, scale `{3, 1.5, 3}`
    - quad floor at `{0.0, 0.5, 0.0}`, scale `{3, 1, 3}`. `run()`
      also pulls the viewer object back to `z = -2.5` so the scene
      is in view at startup.

## `Window.zig` — GLFW Window Management

- **Purpose:** Handle window creation, surface management and
  framebuffer-resize notifications.
- **Type:** Heap-allocated struct (`init` returns `*Self`) with
  `alloc`, `instance`, `width`, `height` and a
  `framebufferResized: bool` flag.
- **Key Functions:**
  - `init(alloc, width, height)` - Create GLFW window, store `self`
    in the window's user-pointer and register the framebuffer-resize
    callback.
  - `deinit()` - Destroy the window, terminate GLFW and free `self`.
  - `should_close()` - Check if a window close was requested.
  - `create_surface(instance, surface)` - Create the Vulkan surface
    for rendering.
  - `getExtent()` - Current size as a `VkExtent2D`.
  - `wasWindowResized()` / `resetWindowResized()` - Read/clear the
    framebuffer-resize flag (polled by `Renderer.endFrame`).
- **Configuration:**
  - No API client (using Vulkan).
  - Resizable window (GLFW_RESIZABLE = GLFW_TRUE); resizes are
    surfaced to the renderer via `framebufferResizeCallback`, which
    updates `width` / `height` and sets `framebufferResized = true`.
  - Uses GLFW C library bindings.

## `Vulkan.zig` — Vulkan Instance & Core Setup

- **Purpose:** Vulkan instance creation, validation layers, and device querying
- **Type:** Struct with `instance` field
- **Key Functions:**
  - `init(alloc, enable_validation_layers)` - Create Vulkan instance
  - `deinit()` - Destroy instance
  - `createLogicalDevice()` - Create logical device from physical device
  - `findQueueFamilies()` - Find graphics and present queue families
  - `checkDeviceExtensionSupport()` - Verify required extensions
  - `querySwapChainSupport()` - Check swapchain capabilities
- **Validation Layers:**
  - `VK_LAYER_KHRONOS_validation` - Used in debug builds
- **Extensions Handled:**
  - Platform-specific extensions (macOS portability)
  - Debug utilities
  - Swapchain extensions
- **Features:**
  - Automatic validation layer detection
  - Debug callback for validation messages
  - Cross-platform extension handling (macOS-specific workarounds)

## `Device.zig` — Physical & Logical Device Management

- **Purpose:** GPU selection and device creation
- **Type:** Struct with device references, queues, and command pool
- **Fields:**
  - `window` - Reference to window
  - `enable_validation_layers` - Debug mode flag
  - `surface` - Vulkan surface
  - `vulkanInstance` - Vulkan instance
  - `physicalDevice` - Selected GPU
  - `properties` - Cached `VkPhysicalDeviceProperties` for the selected
    GPU (so callers can read limits such as
    `properties.limits.minUniformBufferOffsetAlignment` without
    re-querying the driver)
  - `globalDevice` - Logical device
  - `graphicsQueue` - Graphics command queue
  - `presentQueue` - Presentation queue
  - `commandPool` - Command buffer pool
- **Key Functions:**
  - `init(alloc, window)` - Initialize device and queues. Returns a
    heap-allocated `*Self`; `deinit` frees the allocation.
  - `deinit()` - Clean up device resources.
  - `pickPhysicalDevice()` - Select suitable GPU.
  - `isDeviceSuitable()` - Check device capabilities.
  - `createCommandPool()` - Create the command buffer pool.
  - `createShaderModule()` - Compile shader bytecode into a module.
  - `createBuffer(size, usage, properties, buffer, bufferMemory)` -
    Allocate + bind a `VkBuffer` (used by `Model` for both staging
    and DEVICE_LOCAL buffers).
  - `createImageWithInfo(imageInfo, properties, image, imageMemory)` -
    Allocate + bind a `VkImage` (used by the swapchain for the depth
    attachment).
  - `findSupportedFormat(candidates, tiling, features)` /
    `findMemoryType(typeFilter, properties)` - Format and memory-type
    queries against the physical device.
  - `pickMemoryType(memProperties, typeFilter, properties)` -
    Pure-logic helper extracted from `findMemoryType` so the
    bit-fiddling can be unit-tested without a live
    `VkPhysicalDevice`.
  - `beginSingleTimeCommands()` / `endSingleTimeCommands(cb)` -
    Allocate, begin, submit and free a one-shot command buffer on
    the graphics queue, waiting for it to complete.
  - `copyBuffer(src, dst, size)` - Issue a `vkCmdCopyBuffer` inside a
    single-time command buffer (used by `Model` to upload from a
    host-visible staging buffer into a DEVICE_LOCAL buffer).
- **Device Selection Criteria:**
  - Queue family support (graphics and present)
  - Required extension support
  - Swapchain format availability

## `Swapchain.zig` — Swapchain & Frame Resources

- **Purpose:** Owns everything needed to present rendered frames: the
  swapchain itself, color images & views, depth images & views, the
  render pass, framebuffers and per-frame synchronization primitives.
- **Constants:**
  - `MAX_FRAMES_IN_FLIGHT = 2`
- **Key Fields:**
  - `swapChain`, `swapChainImages`, `swapChainImageViews`,
    `swapChainImageFormat`, `swapChainExtent`
  - `depthImages`, `depthImageMemories`, `depthImageViews`,
    `swapChainDepthFormat`
  - `renderPass`, `swapChainFramebuffers`
  - `imageAvailableSemaphores`, `renderFinishedSemaphores`,
    `inFlightFences`, `imagesInFlight`, `currentFrame`
- **Key Functions:**
  - `init(alloc, device, extent, prevSwapChain)` - Builds the swapchain
    (optionally reusing a previous one as `oldSwapchain`), image views,
    render pass, depth resources, framebuffers and sync objects.
  - `deinit()` - Waits for the device to be idle, then tears down every
    Vulkan object it owns.
  - `acquireNextImage(imageIndex)` - Waits on the per-frame fence and
    calls `vkAcquireNextImageKHR`.
  - `submitCommandBuffers(buffers, imageIndex)` - Submits the command
    buffer with appropriate semaphores and presents the image.

## `Renderer.zig` — High-Level Frame Driver

- **Purpose:** Hides swapchain recreation and command-buffer bookkeeping
  behind a small `beginFrame` / `endFrame` API.
- **Fields:** `alloc`, `window`, `device`, optional `swapChain`,
  `commandBuffers`, `currentImageIndex`, `currentFrameIndex`,
  `isFrameStarted`.
- **Key Functions:**
  - `init(alloc, window, device)` - Calls `recreateSwapChain()` and
    allocates per-frame command buffers.
  - `deinit()` - Frees command buffers and the swapchain.
  - `getSwapChainRenderPass()` - Returns the render pass that render
    systems should be built against.
  - `beginFrame()` / `endFrame()` - Acquire/present a swapchain image
    and submit the recorded command buffer. Swapchain recreation is
    triggered automatically on `VK_ERROR_OUT_OF_DATE_KHR`,
    `VK_SUBOPTIMAL_KHR`, or when `Window.wasWindowResized()` reports
    that the framebuffer-resize callback fired. May return
    `error.SwapChainFormatChanged` after a swapchain recreation if
    the image/depth format changed, so callers can rebuild their
    pipelines.
  - `getAspectRatio()` - Convenience accessor for the current
    swapchain extent's aspect ratio (used to update the camera's
    perspective projection per frame).
  - `beginSwapChainRenderPass(cb)` / `endSwapChainRenderPass(cb)` -
    Begin/end the render pass with the current framebuffer, viewport
    and scissor.

## `Pipeline.zig` — Graphics Pipeline Configuration

- **Purpose:** Graphics pipeline creation and configuration.
- **Type:** Struct with pipeline handle, shader modules and a reference
  back to its `Device`.
- **Key Structures:**
  - `PipelineConfigInfo` - Complete pipeline configuration state
    (viewport / scissor info, rasterization, multisample, color blend,
    depth/stencil, dynamic state, `renderPass`, `pipelineLayout`).
- **Key Functions:**
  - `init(alloc, device, fragSpv, vertSpv, configInfo)` - Creates the
    shader modules from embedded SPIR-V and the graphics pipeline.
    The `pipelineLayout` and `renderPass` come from the caller (e.g.
    `SimpleRenderSystem` / `Renderer`).
  - `defaultPipelineConfigInfo()` - Generates the default pipeline
    config used by `SimpleRenderSystem`.
- **Pipeline Configuration (defaultPipelineConfigInfo):**
  - Triangle list topology
  - Fill rasterization, no culling
  - 1x MSAA
  - No color blending
  - Depth test enabled, `LESS` compare
  - Dynamic viewport + scissor

## `SimpleRenderSystem.zig` — GameObject Renderer

- **Purpose:** Owns a `Pipeline` + `VkPipelineLayout` and draws a list
  of `GameObject`s using a per-frame global descriptor set plus
  per-object push constants.
- **Push Constants:**
  - `SimplePushConstantData { modelMatrix: math.Mat4, normalMatrix: math.Mat4 }`
    (used by both vertex and fragment stages). `normalMatrix` is
    stored as a `Mat4` to satisfy std140 alignment; the shader
    extracts it as `mat3(push.normalMatrix)`. The CPU no longer
    multiplies by `projection * view` — that lives in the global UBO
    and the shader does the final multiplication.
- **Key Functions:**
  - `init(alloc, device, renderPass, globalSetLayout)` - Creates the
    pipeline layout (with one descriptor set at set 0 and one
    push-constant range) and the graphics pipeline against
    `renderPass`.
  - `deinit()` - Destroys the pipeline and layout.
  - `renderGameObjects(frameInfo)` - Binds the pipeline, calls
    `vkCmdBindDescriptorSets` once with `frameInfo.globalDescriptorSet`
    (set = 0), then iterates `frameInfo.gameObjects.valueIterator()`
    and, for each `GameObject` with a non-null `model`, uploads
    `obj.transform.mat4()` and `obj.transform.normalMatrix()` as push
    constants and issues a draw via the object's `Model`. Pulls the
    command buffer, the per-frame descriptor set and the scene's
    `GameObject.Map` out of the `*FrameInfo` bundle.
- Embeds `shader.vert.spv` / `shader.frag.spv` via `@embedFile`.

## `Buffer.zig` — VkBuffer + Memory Wrapper

- **Purpose:** Bundles a `VkBuffer`, its backing `VkDeviceMemory`, the
  active mapping (if any), and per-instance / alignment bookkeeping.
  Mirrors `LveBuffer` from the upstream tutorial (itself based on
  Sascha Willems' `VulkanBuffer`).
- **Fields:** `device: *Device`, `mapped: ?*anyopaque`,
  `buffer: c.VkBuffer`, `memory: c.VkDeviceMemory`, plus
  `bufferSize`, `instanceCount`, `instanceSize`, `alignmentSize`,
  `usageFlags`, `memoryPropertyFlags`.
- **Key Functions:**
  - `getAlignment(instanceSize, minOffsetAlignment)` - Pure helper
    that rounds `instanceSize` up to the next multiple of
    `minOffsetAlignment` (or returns it unchanged when alignment is
    `0`). Unit-tested independently of a live `VkDevice`.
  - `init(device, instanceSize, instanceCount, usageFlags,
    memoryPropertyFlags, minOffsetAlignment)` - Creates and binds a
    buffer big enough to hold `instanceCount` slices, each padded to
    `alignmentSize`.
  - `deinit()` - Unmaps any active mapping, destroys the buffer, and
    frees the memory.
  - `map(size, offset)` / `unmap()` - Wraps `vkMapMemory` /
    `vkUnmapMemory`. Pass `c.VK_WHOLE_SIZE` to map the entire buffer.
  - `writeToBuffer(data, size, offset)` - `memcpy` into the mapped
    region. Asserts the buffer is mapped.
  - `flush(size, offset)` / `invalidate(size, offset)` - Wrappers
    around `vkFlushMappedMemoryRanges` /
    `vkInvalidateMappedMemoryRanges`. Required for non-coherent
    memory.
  - `descriptorInfo(size, offset)` - Builds a
    `VkDescriptorBufferInfo` covering the requested range.
  - `writeToIndex(data, index)` / `flushIndex(index)` /
    `invalidateIndex(index)` / `descriptorInfoForIndex(index)` -
    Convenience helpers that operate on the slice at
    `index * alignmentSize`, used to store one `GlobalUbo` per frame
    in flight.

## `FrameInfo.zig` — Per-Frame Render Context

- **Purpose:** Small struct bundling the per-frame state passed into
  render systems each frame, so signatures stay stable as more
  per-frame state (lights, …) is added in later tutorials.
- **Fields:** `frameIndex: usize`, `frameTime: f32`,
  `commandBuffer: c.VkCommandBuffer`, `camera: *Camera`,
  `globalDescriptorSet: c.VkDescriptorSet`,
  `gameObjects: *GameObject.Map` (pointer to the scene's hash-map of
  renderable entities, so render systems iterate the scene directly
  from `FrameInfo`).

## `Descriptors.zig` — Descriptor Set Layouts, Pools & Writers

- **Purpose:** Small wrappers around `VkDescriptorSetLayout`,
  `VkDescriptorPool` and `vkUpdateDescriptorSets`, mirroring the
  upstream `LveDescriptorSetLayout` / `LveDescriptorPool` /
  `LveDescriptorWriter` classes.
- **Types:**
  - `DescriptorSetLayout` - Owns a `VkDescriptorSetLayout` and the
    `AutoHashMapUnmanaged(u32, VkDescriptorSetLayoutBinding)` map
    used by `DescriptorWriter` to validate writes.
    - `Builder.init(alloc, device)` / `addBinding(binding,
      descriptorType, stageFlags, count)` / `build()` constructs the
      layout, transferring ownership of the bindings map into the
      returned `DescriptorSetLayout`.
  - `DescriptorPool` - Owns a `VkDescriptorPool`.
    - `Builder.init(alloc, device)` / `addPoolSize(descriptorType,
      count)` / `setPoolFlags(flags)` / `setMaxSets(count)` /
      `build()` constructs the pool (default `maxSets = 1000`).
    - `allocateDescriptor(layout, &set) -> bool`,
      `freeDescriptors([]VkDescriptorSet)`, `resetPool()`.
  - `DescriptorWriter` - Accumulates `VkWriteDescriptorSet`s and
    either allocates a new descriptor set from a pool (`build`) or
    updates an existing one (`overwrite`).
    - `init(alloc, *DescriptorSetLayout, *DescriptorPool)`,
      `writeBuffer(binding, *VkDescriptorBufferInfo)`,
      `writeImage(binding, *VkDescriptorImageInfo)`,
      `build(&set) -> bool`, `overwrite(set)`.
- None of these own a `*Device`; the caller (typically `FirstApp`)
  manages that lifetime.

## `Model.zig` — Vertex + Index Buffer Wrapper

- **Purpose:** Encapsulates a Vulkan vertex buffer and an optional
  index buffer, and exposes a Zig `Vertex` type matching the shader
  inputs. The vertex / index buffers are owned `Buffer` instances,
  mirroring the `std::unique_ptr<LveBuffer>` fields in the upstream
  C++ tutorial. Delegates OBJ parsing to tinyobjloader through a
  small C-ABI wrapper (`src/wrapper/tinyobj/`; see that directory's
  `README.md` for why the wrapper exists).
- **Vertex Layout:**
  - `position: math.Vec3` at location 0 (`R32G32B32_SFLOAT`)
  - `color: math.Vec3` at location 1 (`R32G32B32_SFLOAT`)
  - `normal: math.Vec3` at location 2 (`R32G32B32_SFLOAT`)
  - `uv: math.Vec2` at location 3 (`R32G32_SFLOAT`)
- **`Builder` struct:** mirrors the upstream C++ tutorial's
  `LveModel::Builder`. Owns its `vertices: ArrayList(Vertex)` and
  `indices: ArrayList(u32)` storage; call `deinit(alloc)` once a
  `Model` has been constructed from it. `indices` may be empty, in
  which case the model falls back to non-indexed drawing via
  `vkCmdDraw`.
- **Key Functions:**
  - `Vertex.getBindingDescriptions()` / `getAttributeDescriptions()` -
    Used by `Pipeline` to wire up vertex input.
  - `Builder.loadModel(alloc, obj_bytes)` - Calls
    `tinyobj_load_bytes` (declared in
    `src/wrapper/tinyobj/tinyobj_wrapper.h`, imported via `c.zig`).
    The wrapper feeds the bytes to `tinyobj::LoadObj` through a
    `std::istringstream`, triangulates polygonal faces, and
    deduplicates exactly-matching vertices via `std::unordered_map`
    (mirroring `lve_model.cpp` in the C++ tutorial). The Zig side then
    copies the returned flat arrays into the `Builder`'s
    `ArrayList`s, converting the C struct layout into the
    `@Vector`-backed `Vertex` used by Zig.
  - `createModelFromFile(device, alloc, obj_bytes)` - Convenience
    factory that builds a `Builder`, calls `loadModel` and returns a
    fully-constructed `Model`. Mirrors `LveModel::createModelFromFile`
    in the C++ tutorial.
  - `init(device, builder)` - Creates a DEVICE_LOCAL vertex `Buffer`
    (and, if `builder.indices.items.len > 0`, a DEVICE_LOCAL index
    `Buffer`) and uploads the data through a host-visible /
    host-coherent staging `Buffer` via `Device.copyBuffer`. Partial
    allocations are released through `errdefer` on failure.
  - `deinit()` - Calls `Buffer.deinit` on the vertex buffer and, when
    present, the index buffer (each releases its own
    `VkBuffer` + `VkDeviceMemory`).
  - `bind(commandBuffer)` - Bind the vertex buffer and, when present,
    the index buffer (`VK_INDEX_TYPE_UINT32`).
  - `draw(commandBuffer)` - Issues `vkCmdDrawIndexed` when an index
    buffer is present and `vkCmdDraw` otherwise.

## `GameObject.zig` — Renderable Entity

- **Purpose:** A simple renderable: id, optionally owned `Model`, color
  and a `TransformComponent`.
- **TransformComponent:** `translation`, `scale`, `rotation` (all
  `math.Vec3`) with a `mat4()` method that builds
  `Translate * Ry * Rx * Rz * Scale` using Tait-Bryan Y(1)-X(2)-Z(3)
  angles, plus a `normalMatrix()` helper that returns the matching
  normal matrix (`R * diag(1/scale)`, identity-extended to `Mat4` so
  it fits in the push-constant layout the shader expects).
- **Key Functions:**
  - `init(model, color, transform)` - Auto-assigns a monotonically
    increasing `id_t`; the object owns the model.
  - `createGameObject()` - Factory for a model-less object (used for
    the camera "viewer" object driven by the keyboard controller).
  - `deinit()` - Tears down the owned `Model` if any.
  - `getId()` - Returns the object's id.
- **Map alias:** `GameObject.Map = std.AutoHashMapUnmanaged(u64, GameObject)`
  mirrors the upstream `LveGameObject::Map`
  (`std::unordered_map<id_t, LveGameObject>`). `FirstApp` owns the
  scene's `Map`, and renders by passing a `*GameObject.Map` into
  `FrameInfo`.

## `KeyboardMovementController.zig` — Camera Input

- **Purpose:** Translate keyboard input into transform changes on a
  `GameObject`. Used by `FirstApp` to drive the camera's view object.
- **Default key mappings** (overridable via `keys: KeyMappings`):
  - Movement: `W` / `S` (forward / back), `A` / `D` (strafe left /
    right), `E` / `Q` (up / down in world space).
  - Look: arrow keys for yaw (`Left` / `Right`) and pitch (`Up` /
    `Down`).
- **Tunables:** `moveSpeed` (default `3.0` units/s), `lookSpeed`
  (default `1.5` rad/s).
- **Key Functions:**
  - `moveInPlaneXZ(window, dt, gameObject)` - Reads currently-pressed
    keys, normalizes the rotation/translation deltas, integrates them
    over `dt`, clamps pitch to roughly +/- 85° and wraps yaw into
    `[0, 2*pi)`.

## `Camera.zig` — View / Projection Helpers

View/projection matrix helpers: orthographic, perspective,
`setViewDirection` / `setViewTarget` / `setViewYXZ`.

## `Loop.zig` — Main Event Loop

- **Purpose:** Application event processing
- **Type:** Struct with window reference
- **Key Functions:**
  - `init(window)` - Initialize event loop and install POSIX signal handlers
  - `deinit()` - Clean up
  - `is_running()` - Check if should continue
- **Current Implementation:**
  - Delegates to window's `should_close()` check
  - Uses GLFW event polling in main loop
  - **Graceful shutdown via signals:** `Loop.init` installs handlers for
    `SIGINT`, `SIGTERM`, and `SIGHUP` (no-op on Windows). The handlers set
    an atomic `shutdown_requested` flag that `is_running()` polls, so the
    main loop exits cleanly and all `defer`/`deinit` paths run. To close
    the app programmatically from another process, send any of these
    signals, e.g.:
    ```bash
    kill -INT  <pid>   # same as Ctrl+C
    kill -TERM <pid>
    kill -HUP  <pid>
    ```
    `pkill vulkan_engine` works as well. Avoid `kill -9` / `SIGKILL`,
    since it bypasses the handler and skips Vulkan/GLFW cleanup.

## `c.zig` — C FFI Layer

- **Purpose:** C interoperability bindings.
- **Content:**
  - `c` - `@cImport` of `GLFW/glfw3.h`, `vulkan/vulkan_beta.h` (with
    `GLFW_INCLUDE_VULKAN` defined) and the in-tree
    `tinyobj_wrapper.h`.
- **Usage:** Vulkan / GLFW / tinyobjloader-wrapper calls go through
  `c`. Math types are provided by the in-tree `math.zig` module (Zig
  `@Vector`-based `Vec2`/`Vec3`/`Vec4` and `Mat4`); no external math
  library is required.

## `math.zig` — Linear Algebra Helpers

- **Purpose:** Small, dependency-free linear-algebra module built on
  the `@Vector` SIMD types of Zig.
- **Types:**
  - `Vec2 = @Vector(2, f32)`
  - `Vec3 = @Vector(3, f32)`
  - `Vec4 = @Vector(4, f32)`
  - `Mat4 = [4]Vec4` (column-major)
  - `identity_mat4: Mat4`
- **Functions:**
  - `dot3(a, b)`, `length3(v)`, `normalize3(v)`, `cross3(a, b)`
  - `mul4(a, b)` — column-major 4x4 matrix multiplication.
- All vector arithmetic uses the built-in element-wise vector
  operators (`+`, `-`, `*`, `/`) of the language rather than explicit
  per-component loops.

## `utils.zig` — Utility Functions

- **Purpose:** Common utility functions
- **Key Functions:**
  - `checkSuccess(result)` - Validate Vulkan result codes
  - Converts Vulkan errors to Zig error types

## `wrapper/tinyobj/` — C++ tinyobjloader Wrapper

C-ABI shim over the C++ tinyobjloader library, used by `Model.zig`'s
`Builder.loadModel` via `c.zig`. See
[`src/wrapper/tinyobj/README.md`](../src/wrapper/tinyobj/README.md) for
the C++/C boundary rationale. Compiled into the executable by
`build.zig` with `link_libc` + `link_libcpp` enabled on every
platform.
