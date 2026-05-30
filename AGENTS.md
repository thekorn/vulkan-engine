# Vulkan Engine - Project Architecture & Structure

## 1. Build System

**Build System:** Zig Build System

- **Language:** Zig (systems programming language)
- **Minimum Version:** 0.16.0
- **Files:**
  - `build.zig` - Main build configuration
  - `build.zig.zon` - Zig dependency manifest (currently has no external dependencies)

### Build Features

- **Shader Compilation:** Automatic GLSL to SPIR-V compilation using `glslc`
  - Shaders are discovered by walking `shaders/` via `std.Io.Dir` (Zig 0.16 std.Io API)
  - Compiled outputs are added as anonymous module imports and embedded via `@embedFile` in `main.zig`
  - Located in `compileAllShaders()` function
- **System Library Linking:**
  - `glfw3` - Window and input management
  - `vulkan` - Vulkan API
  - `gl` - On Linux only
- **Test Infrastructure:** Built-in test support via `zig build test`

### Development Setup

Two options for local development:

**Option 1 - Nix (Recommended):**

```bash
nix develop
nix develop --command zig build run
```

**Option 2 - Manual Setup:**
Install required dependencies:

- Zig 0.16.0
- GLFW3
- Vulkan SDK
- shaderc/glslc (for shader compilation)

### Build Commands

```bash
zig build              # Build executable
zig build run          # Build and run
zig build test         # Run tests
zig build coverage     # Run tests under kcov, write report to zig-out/cover (Linux only)
zig build test -Dcover -Dopen   # Run tests under kcov and open the HTML report
```

Whenever kcov runs (via either `zig build coverage` or `zig build test
-Dcover`), a compact summary is printed at the end of the terminal
output: an overall percentage followed by a per-file breakdown sorted
worst-first. It reads the per-run `coverage.json` produced by kcov via
`jq`, so `jq` must be on `PATH` (provided by the Nix dev shell).

### Spell Checking

The project uses [`codebook`](https://github.com/blopker/codebook) for
spell-checking source and documentation. The project dictionary lives in
`codebook.toml`.

Always run the spell checker together with the test suite:

```bash
nix develop --command zig build test --summary all
nix develop --command codebook-lsp lint --unique -s .
```

CI (see `.github/workflows/ci.yaml`) runs both `codebook-lsp lint .` and
`zig build test`; treat the spell check as a required part of "running the
tests" and resolve any reported words either by fixing the spelling or, when
the term is a legitimate technical word, by adding it to `codebook.toml`.

---

## 2. Project Directory Structure

```
vulkan-engine/
├── build.zig              # Build configuration (Zig build system)
├── build.zig.zon          # Zig manifest/dependencies
├── flake.nix              # Nix development environment
├── flake.lock             # Pinned Nix inputs
├── README.md              # Basic project info
├── AGENTS.md              # This file (project guidance for agents)
├── codebook.toml          # Codebook configuration
├── .agents/
│   └── skills/            # Agent skills (e.g. zig 0.16 porting notes)
├── .github/
│   └── workflows/
│       └── ci.yaml        # GitHub Actions CI/CD
├── src/                   # Core application source
│   ├── main.zig             # Entry point (delegates to FirstApp)
│   ├── FirstApp.zig         # Top-level application: owns window, device,
│   │                        #   loop, renderer and game objects
│   ├── Vulkan.zig           # Vulkan instance & initialization
│   ├── Device.zig           # Physical/logical device management,
│   │                        #   buffer / image / command-pool helpers
│   ├── Window.zig           # GLFW window management & surface creation
│   ├── Swapchain.zig        # Swapchain, depth resources, render pass,
│   │                        #   framebuffers, synchronization, acquire /
│   │                        #   submit-present (MAX_FRAMES_IN_FLIGHT = 2)
│   ├── Renderer.zig         # High-level frame driver: owns the swapchain
│   │                        #   and per-frame command buffers, exposes
│   │                        #   beginFrame / beginSwapChainRenderPass /
│   │                        #   endSwapChainRenderPass / endFrame
│   ├── Pipeline.zig         # Graphics pipeline configuration & creation
│   ├── SimpleRenderSystem.zig # Pipeline + push-constant based renderer
│   │                          # that draws a list of GameObjects
│   ├── Model.zig            # Vertex buffer wrapper; defines `Vertex`
│   │                        #   (position + color) with binding /
│   │                        #   attribute descriptions
│   ├── GameObject.zig       # Renderable entity: id, optional model,
│   │                        #   color and TransformComponent
│   │                        #   (translation / scale / rotation -> mat4
│   │                        #   via Tait-Bryan Y-X-Z); also provides a
│   │                        #   `createGameObject()` factory for
│   │                        #   model-less objects (e.g. the camera
│   │                        #   "viewer" object)
│   ├── KeyboardMovementController.zig
│   │                        # WASD + QE position + arrow-key look
│   │                        #   controller that drives a GameObject's
│   │                        #   TransformComponent
│   ├── Camera.zig           # View/projection matrix helpers
│   │                        #   (orthographic, perspective,
│   │                        #   setViewDirection / setViewTarget /
│   │                        #   setViewYXZ)
│   ├── Loop.zig             # Main event loop & POSIX signal handling
│   ├── c.zig                # C interop: GLFW + Vulkan @cImport
│   ├── math.zig             # Linear-algebra helpers (Vec2/3/4, Mat4,
│   │                        #   dot/cross/normalize/length/mul4) built
│   │                        #   on Zig's `@Vector` SIMD types
│   └── utils.zig            # Utility functions (Vulkan result checking)
├── shaders/               # GLSL shader source files
│   ├── shader.vert        # Vertex shader (push-constant transform, color)
│   └── shader.frag        # Fragment shader (writes vertex color)
├── test_runner.zig        # Custom Zig test runner
└── zig-out/               # Build output directory (generated)
```

---

## 3. Core Architectural Components

### 3.1 Component Overview

The engine follows a layered architecture with clear separation of concerns.
`main.zig` is just a thin entry point; the real application lives in
`FirstApp.zig`, which composes a window, device, loop, renderer and a list
of `GameObject`s, and drives them via a `SimpleRenderSystem` inside its
`run()` loop.

```
main.zig (Entry Point)
    ↓
FirstApp.zig (Application root)
    ├── Window.zig   (GLFW window + surface)
    ├── Device.zig   (physical/logical device, queues, command pool,
    │                 buffer/image helpers)
    │     ↓
    │   Vulkan.zig   (instance, validation layers, extension queries)
    ├── Loop.zig     (event loop + signal handling)
    ├── Renderer.zig (owns Swapchain + per-frame command buffers)
    │     ↓
    │   Swapchain.zig (images, image views, depth, render pass,
    │                  framebuffers, sync, acquire/present)
    ├── SimpleRenderSystem.zig
    │     └── Pipeline.zig (graphics pipeline, shader modules)
    ├── Camera.zig (projection + view matrices)
    ├── KeyboardMovementController.zig (drives a viewer GameObject
    │                                    from keyboard input)
    └── GameObject.zig (optional Model + TransformComponent + color)
              ↓
          Model.zig (Vertex buffer)
              ↓
          c.zig (GLFW / Vulkan FFI) + math.zig
              ↓
          External Libraries (GLFW, Vulkan)
```

### 3.2 Component Descriptions

#### **main.zig** - Entry Point

- **Purpose:** Construct the top-level application and run it.
- **Key Functions:**
  - `main()` - Creates a page allocator, initializes `FirstApp`, runs it
    and `defer`s `deinit`.
- All test imports for the test runner are also registered here.

#### **FirstApp.zig** - Application Root

- **Purpose:** Owns the full application lifetime and the per-frame loop.
- **Window Size:** 800x600 (`FirstApp.width` / `FirstApp.height`)
- **Fields:**
  - `alloc` - Allocator passed in from `main`
  - `window: *Window`, `device: *Device` - heap-allocated, stable
    back-references for sub-components
  - `loop: Loop`, `renderer: Renderer`
  - `gameObjects: ArrayList(GameObject)`
- **Key Functions:**
  - `init(alloc)` - Wires up window → device → loop → renderer, then calls
    `loadGameObjects()`.
  - `deinit()` - Tears everything down in reverse order.
  - `run()` - Main loop:
    1. Build a `SimpleRenderSystem`, a `Camera`, a model-less
       `viewerObject` (via `GameObject.createGameObject`) and a
       `KeyboardMovementController`.
    2. Poll GLFW events.
    3. Compute `frameTime` (seconds) from `glfwGetTime()`.
    4. `cameraController.moveInPlaneXZ(...)` updates the viewer
       object's transform from keyboard input.
    5. `camera.setViewYXZ(...)` syncs the camera to the viewer
       object's translation/rotation, then `setPerspectiveProjection`
       updates the projection.
    6. `renderer.beginFrame()` → `beginSwapChainRenderPass` →
       `simpleRenderSystem.renderGameObjects` →
       `endSwapChainRenderPass` → `endFrame`.
    7. If the swapchain has to be recreated and reports
       `error.SwapChainFormatChanged`, the render system is rebuilt
       against the new render pass and the frame is skipped.
    8. `vkDeviceWaitIdle` before returning so the GPU is finished with
       everything before resources are destroyed.
  - `createCubeModel()` / `loadGameObjects()` - Temporary helpers that
    build a single colored cube `Model` and wrap it in a `GameObject`.

#### **Window.zig** - GLFW Window Management

- **Purpose:** Handle window creation and surface management
- **Type:** Struct with `instance`, `width`, `height` fields
- **Key Functions:**
  - `init(width, height)` - Create GLFW window
  - `deinit()` - Clean up window resources
  - `should_close()` - Check if window close requested
  - `create_surface(instance, surface)` - Create Vulkan surface for rendering
- **Configuration:**
  - No API client (using Vulkan)
  - Non-resizable window
  - Uses GLFW C library bindings

#### **Vulkan.zig** - Vulkan Instance & Core Setup

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

#### **Device.zig** - Physical & Logical Device Management

- **Purpose:** GPU selection and device creation
- **Type:** Struct with device references, queues, and command pool
- **Fields:**
  - `window` - Reference to window
  - `enable_validation_layers` - Debug mode flag
  - `surface` - Vulkan surface
  - `vulkanInstance` - Vulkan instance
  - `physicalDevice` - Selected GPU
  - `globalDevice` - Logical device
  - `graphicsQueue` - Graphics command queue
  - `presentQueue` - Presentation queue
  - `commandPool` - Command buffer pool
- **Key Functions:**
  - `init(alloc, window)` - Initialize device and queues
  - `deinit()` - Clean up device resources
  - `pickPhysicalDevice()` - Select suitable GPU
  - `isDeviceSuitable()` - Check device capabilities
  - `createCommandPool()` - Create command buffer pool
  - `createShaderModule()` - Compile shader bytecode into module
- **Device Selection Criteria:**
  - Queue family support (graphics and present)
  - Required extension support
  - Swapchain format availability

#### **Swapchain.zig** - Swapchain & Frame Resources

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

#### **Renderer.zig** - High-Level Frame Driver

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
    and submit the recorded command buffer. May return
    `error.SwapChainFormatChanged` after a swapchain recreation if the
    image/depth format changed, so callers can rebuild their pipelines.
  - `beginSwapChainRenderPass(cb)` / `endSwapChainRenderPass(cb)` -
    Begin/end the render pass with the current framebuffer, viewport
    and scissor.

#### **Pipeline.zig** - Graphics Pipeline Configuration

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

#### **SimpleRenderSystem.zig** - GameObject Renderer

- **Purpose:** Owns a `Pipeline` + `VkPipelineLayout` and draws a list
  of `GameObject`s using push constants.
- **Push Constants:**
  - `SimplePushConstantData { transform: math.Mat4, color: math.Vec3 }`
    (used by both vertex and fragment stages)
- **Key Functions:**
  - `init(alloc, device, renderPass)` - Creates the pipeline layout
    (with one push-constant range) and the graphics pipeline against
    `renderPass`.
  - `deinit()` - Destroys the pipeline and layout.
  - `renderGameObjects(commandBuffer, gameObjects)` - Binds the
    pipeline, then for each `GameObject` uploads its transform/color as
    push constants and issues a draw via the object's `Model`.
- Embeds `shader.vert.spv` / `shader.frag.spv` via `@embedFile`.

#### **Model.zig** - Vertex Buffer Wrapper

- **Purpose:** Encapsulates a Vulkan vertex buffer and exposes a Zig
  `Vertex` type matching the shader inputs.
- **Vertex Layout:**
  - `position: math.Vec3` at location 0 (`R32G32B32_SFLOAT`)
  - `color: math.Vec3` at location 1 (`R32G32B32_SFLOAT`)
- **Key Functions:**
  - `Vertex.getBindingDescriptions()` / `getAttributeDescriptions()` -
    Used by `Pipeline` to wire up vertex input.
  - `init(device, vertices)` - Allocates a host-visible / host-coherent
    vertex buffer and uploads the vertex data.
  - `deinit()` - Destroys the buffer and frees its memory.
  - `bind(commandBuffer)` / `draw(commandBuffer)` - Bind the vertex
    buffer and issue a non-indexed draw.

#### **GameObject.zig** - Renderable Entity

- **Purpose:** A simple renderable: id, optionally owned `Model`, color
  and a `TransformComponent`.
- **TransformComponent:** `translation`, `scale`, `rotation` (all
  `math.Vec3`) with a `mat4()` method that builds
  `Translate * Ry * Rx * Rz * Scale` using Tait-Bryan Y(1)-X(2)-Z(3)
  angles.
- **Key Functions:**
  - `init(model, color, transform)` - Auto-assigns a monotonically
    increasing `id_t`; the object owns the model.
  - `createGameObject()` - Factory for a model-less object (used for
    the camera "viewer" object driven by the keyboard controller).
  - `deinit()` - Tears down the owned `Model` if any.
  - `getId()` - Returns the object's id.

#### **KeyboardMovementController.zig** - Camera Input

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

#### **Loop.zig** - Main Event Loop

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

#### **c.zig** - C FFI Layer

- **Purpose:** C interoperability bindings.
- **Content:**
  - `c` - `@cImport` of `GLFW/glfw3.h` and `vulkan/vulkan_beta.h` with
    `GLFW_INCLUDE_VULKAN` defined.
- **Usage:** Vulkan / GLFW calls go through `c`. Math types are
  provided by the in-tree `math.zig` module (Zig `@Vector`-based
  `Vec2`/`Vec3`/`Vec4` and `Mat4`); no external math library is
  required.

#### **math.zig** - Linear Algebra Helpers

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

#### **utils.zig** - Utility Functions

- **Purpose:** Common utility functions
- **Key Functions:**
  - `checkSuccess(result)` - Validate Vulkan result codes
  - Converts Vulkan errors to Zig error types

### 3.3 Data Flow

**Initialization Flow:**

```
main.zig
  └─→ FirstApp.init(alloc)
       ├─→ Window.init()      glfwInit() + glfwCreateWindow()
       ├─→ Device.init()
       │    ├─→ Vulkan.init()           vkCreateInstance()
       │    ├─→ Window.create_surface() glfwCreateWindowSurface()
       │    ├─→ pickPhysicalDevice()    vkEnumeratePhysicalDevices()
       │    ├─→ createLogicalDevice()   vkCreateDevice()
       │    └─→ createCommandPool()
       ├─→ Loop.init()                  install signal handlers
       ├─→ Renderer.init()
       │    ├─→ recreateSwapChain()
       │    │    └─→ Swapchain.init()   images, views, depth,
       │    │                           render pass, framebuffers,
       │    │                           sync objects
       │    └─→ createCommandBuffers()
       └─→ loadGameObjects()
            └─→ Model.init() + GameObject.init()
```

**Runtime Flow (`FirstApp.run`):**

```
SimpleRenderSystem.init(renderer.getSwapChainRenderPass())
camera           = Camera{}
viewerObject     = GameObject.createGameObject()   // no model
cameraController = KeyboardMovementController{}
currentTime      = glfwGetTime()

while Loop.is_running():
  glfwPollEvents()

  newTime   = glfwGetTime()
  frameTime = newTime - currentTime
  currentTime = newTime

  cameraController.moveInPlaneXZ(window, frameTime, &viewerObject)
  camera.setViewYXZ(viewerObject.transform.translation,
                    viewerObject.transform.rotation)
  camera.setPerspectiveProjection(radians(50), aspect, 0.1, 10)

  cb = renderer.beginFrame()    // acquires next image, begins recording
  if cb != null:
    renderer.beginSwapChainRenderPass(cb)
    simpleRenderSystem.renderGameObjects(cb, gameObjects, &camera)
    renderer.endSwapChainRenderPass(cb)
    renderer.endFrame()         // submits + presents
  // On error.SwapChainFormatChanged → rebuild SimpleRenderSystem
  //   against the new render pass and continue.

vkDeviceWaitIdle(device)        // before deinit
```

---

## 4. Vulkan Rendering Pipeline Organization

### 4.1 Pipeline Architecture

The rendering pipeline is structured in stages following the Vulkan graphics pipeline model:

**1. Instance & Device Setup**

- Location: `Vulkan.zig` + `Device.zig`
- Creates Vulkan instance with platform-specific extensions
- Selects suitable physical device
- Creates logical device with graphics and presentation queues

**2. Surface & Swapchain**

- Location: `Window.zig` + `Swapchain.zig`
- Surface is created via `glfwCreateWindowSurface`.
- `Swapchain.zig` owns the swapchain, color/depth images, image views,
  the render pass, framebuffers and per-frame sync primitives. It
  supports recreation (e.g. on window resize) by passing in the
  previous swapchain as `oldSwapchain`.

**3. Shader Compilation**

- Location: `build.zig` + `shaders/`
- Build-time: `glslc` compiles every file under `shaders/` to SPIR-V.
- Runtime: SPIR-V is added as anonymous module imports and embedded via
  `@embedFile` in `SimpleRenderSystem.zig`.
- Files:
  - `shader.vert` - Vertex shader (push-constant transform, vertex color)
  - `shader.frag` - Fragment shader (writes interpolated vertex color)

**4. Graphics Pipeline & Render System**

- Location: `Pipeline.zig` + `SimpleRenderSystem.zig`
- `Pipeline` owns the shader modules and the `VkPipeline`.
- `SimpleRenderSystem` owns the `VkPipelineLayout` (with one push
  constant range covering `SimplePushConstantData`) and the `Pipeline`,
  and is built against a render pass obtained from `Renderer`.

**5. Frame Rendering**

- Location: `Renderer.zig` + `FirstApp.zig`
- `Renderer.beginFrame` acquires a swapchain image and starts recording
  the per-frame command buffer; `beginSwapChainRenderPass` begins the
  render pass with the current framebuffer, viewport and scissor.
- `SimpleRenderSystem.renderGameObjects` binds the pipeline, uploads
  push constants and issues draws per `GameObject` via its `Model`.
- `endSwapChainRenderPass` + `endFrame` submit the command buffer and
  present. Swapchain recreation is handled transparently; if the
  format changes, `Renderer` returns `error.SwapChainFormatChanged` so
  callers can rebuild their pipelines/render systems.

### 4.2 Shader Details

**Vertex Shader (`shader.vert`):**

```glsl
#version 450

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 color;

layout(location = 0) out vec3 fragColor;

layout(push_constant) uniform Push {
    mat4 transform;
    vec3 color;
} push;

void main() {
    gl_Position = push.transform * vec4(position, 1.0);
    fragColor   = color;
}
```

**Fragment Shader (`shader.frag`):**

```glsl
#version 450

layout(location = 0) in  vec3 fragColor;
layout(location = 0) out vec4 outColor;

layout(push_constant) uniform Push {
    mat4 transform;
    vec3 color;
} push;

void main() {
    outColor = vec4(fragColor, 1.0);
}
```

**Current State:** Renders a single colored cube (`createCubeModel`) as
a `GameObject` driven by `SimpleRenderSystem`.

### 4.3 Key Configuration Parameters

**Viewport & Scissor:**

- Viewport size: 800x600
- Depth range: 0.0 to 1.0

**Rasterization:**

- Polygon mode: Fill
- Cull mode: None
- Front face: Clockwise
- Line width: 1.0

**Color Blending:**

- Disabled (no blending operations)
- RGBA write mask: All channels enabled

**Depth Stencil:**

- Depth test: Enabled
- Depth write: Enabled
- Depth compare op: Less
- Stencil test: Disabled

---

## 5. Configuration Files

### 5.1 Build Configuration

**build.zig**

- Zig build system configuration
- Handles shader compilation (`glslc` per file under `shaders/`)
- Links system libraries (`glfw3`, `vulkan`; `gl` on Linux)
- Defines build steps (`run`, `test`)
- Uses a custom test runner (`test_runner.zig`, simple mode)
- Target and optimization settings

**build.zig.zon**

- Package metadata
- Project name: `vulkan_engine`
- Version: 0.0.0
- Minimum Zig version: 0.16.0
- Dependencies: None (using system libraries)

### 5.2 Development Environment

**flake.nix**

- Nix package manager configuration
- Provides reproducible development environment
- Dependencies:
  - `zig_0_16` - Compiler
  - `zls_0_16` - Language server
  - `codebook` - Spell checker (`codebook-lsp` binary)
  - `cloc` - Lines-of-code report
  - `jq` - JSON formatter, used by the coverage summary printer in
    `build.zig`
  - `shaderc` - Shader compilation
  - `vulkan-headers`, `vulkan-loader(.dev)`, `vulkan-validation-layers`
  - `glfw` - Window system
  - `pkg-config` - Dependency discovery
  - Platform-specific: `libGL(.dev)` on Linux
- Sets `VK_LAYER_PATH` to the validation layers from `vulkan-validation-layers`.

### 5.3 CI/CD Configuration

**.github/workflows/ci.yaml**

- GitHub Actions workflow
- Triggers on PR and push to main
- Runs on Ubuntu Linux
- Steps:
  1. Checkout repository
  2. Install Nix (Determinate Systems installer + magic Nix cache)
  3. Run `nix flake check`
  4. Spell check: `nix develop -c codebook-lsp lint .`
  5. Build & tests: `nix develop -c zig build test --summary all`
  6. Coverage: `nix develop -c zig build coverage --summary all`
  7. Upload the full HTML report as the `coverage-report` artifact
  8. On `push` to `main`: upload `coverage.json` (via the stable
     `zig-out/cover/test/` symlink kcov maintains) as the
     `coverage-main` artifact so PRs can diff against it
  9. On `pull_request`: download the latest `coverage-main` artifact
     from `main` and post a sticky PR comment with the overall
     coverage and the per-file delta vs `main` (via
     `actions/github-script`).
- Concurrency control to cancel outdated runs
- The PR comment uses `<!-- coverage-comment -->` as a marker so it is
  updated in place on subsequent pushes instead of accumulating.

### 5.4 Git Configuration

**.gitignore**

- Ignores: `zig-out/`, `.zig-cache/`, `*.cpp`, `*.hpp`
- Allows: source code, build files, configuration

---

## 6. Test Setup

### 6.1 Test Infrastructure

**Testing Framework:**

- Built into Zig language
- Uses `@import("builtin")` for compile-time checks
- Test declarations with `test` keyword
- Custom runner: `test_runner.zig` (`mode = .simple`)

**Current Test Setup:**

- Located in: Individual source files; all aggregated via the `test {}`
  block at the bottom of `src/main.zig` (which `_ = @import`s every
  module so their tests are discovered).
- Test execution: `zig build test`
- CI integration: GitHub Actions runs tests on every PR/push.

**Running Tests (always run the spell checker alongside!):**

```bash
zig build test                                   # Local testing
zig build test --summary all                     # Detailed summary
nix develop -c zig build test --summary all      # In Nix environment

# Spell check — REQUIRED part of "running the tests":
nix develop --command codebook-lsp lint --unique -s .
```

The `--unique` flag deduplicates findings and `-s` makes the output
suitable for scripts / CI logs. When introducing a new word, prefer
fixing the typo; if the word is a legitimate technical term, add it to
the `words` array in `codebook.toml`.

### 6.2 Test Infrastructure in CI

- Runs on Ubuntu Linux
- Uses Nix for reproducible environment
- Runs `codebook-lsp lint .` as a dedicated step
- Executes full build and test suite via `zig build test --summary all`
- Generates test summary

### 6.3 Notable Test Features

- No external test framework required (Zig built-in)
- Tests run at compile time when possible
- Can be run in debug and release modes
- Spell checking is treated as a required check, equivalent in
  importance to the Zig test suite.

---

## 7. Key Architectural Patterns

### 7.1 Design Patterns Used

**1. Resource Acquisition Is Initialization (RAII)**

- Each component has `init()` and `deinit()` functions
- Deferred cleanup using `defer` keyword
- Automatic resource management

**2. Struct-Based Components**

- Core components are Zig structs (implicit types via `@This()`)
- Self-contained with encapsulated state
- Methods return modified copies or mutate in-place

**3. C Interoperability Layer**

- Abstraction via `c.zig` module
- Centralized C binding management
- Error handling via `checkSuccess()` wrapper

**4. Configuration Objects**

- `PipelineConfigInfo` - Encapsulates pipeline state
- Allows flexible configuration through builder pattern
- `defaultPipelineConfigInfo()` provides sensible defaults

**5. Allocator Pattern**

- Explicit memory allocation via `std.mem.Allocator`
- Page allocator used in main
- Deferred cleanup for temporary allocations

### 7.2 Error Handling

**Error Management:**

- Zig error union types (`!Type`)
- Try operator (`try`) for error propagation
- `checkSuccess()` converts Vulkan error codes to Zig errors
- Validation layer support for runtime errors

**Example Error Handling:**

```zig
try checkSuccess(c.vkCreateDevice(...))  // Propagates errors
_ = c.vkEnumeratePhysicalDevices(...)    // Ignores result
```

### 7.3 Memory Management

**Allocation Strategy:**

- Page allocator for main application lifetime
- ArrayList for dynamic collections
- Explicit deallocation with `defer`
- No garbage collection (manual management)

**Example:**

```zig
var extensions: std.ArrayList(...) = .empty;
defer extensions.deinit(alloc);
```

---

## 8. Development Notes

### 8.1 Platform-Specific Considerations

**macOS Support:**

- Handles VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME
- Requires VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME
- Portability subset extension required

**Linux Support:**

- Includes GL library linking
- Tested in CI pipeline

### 8.2 Known Limitations & TODOs

- Validation layer cleanup incomplete — debug messenger destruction is
  TODO (see `Device.deinit`).
- Only a single hardcoded scene (one colored cube wired up in
  `FirstApp.loadGameObjects`).
- No camera / view-projection matrix yet; transforms are applied directly
  via push constants.
- No descriptor sets / uniform buffers; only push constants are used.
- No indexed drawing (`Model.draw` is `vkCmdDraw`, not `vkCmdDrawIndexed`).
- No asset loading (models / textures); geometry is built in code.

### 8.3 Extension References

- Based on Vulkan Tutorial (vulkan-tutorial.com)
- Inspired by Little Vulkan Engine by Brendan Galea
- Related projects: rift-engine

---

## 9. Quick Start for Development

### Setup (with Nix)

```bash
cd /Users/thekorn/devel/github.com/thekorn/vulkan-engine
nix develop
zig build run
```

### Build Targets

```bash
zig build              # Compile executable
zig build run          # Compile and run
zig build test         # Run test suite
zig build --help       # Show all options

# Spell check (always run with tests):
nix develop --command codebook-lsp lint --unique -s .
```

### Key File Locations

- Entry point: `/src/main.zig`
- Application root: `/src/FirstApp.zig`
- Shader sources: `/shaders/`
- Build config: `/build.zig`
- Custom test runner: `/test_runner.zig`
- Spell-check dictionary: `/codebook.toml`
- Dev environment: `/flake.nix`

### IDE Support

- ZLS (Zig Language Server) included in Nix env
- Requires editor with LSP support

---

## 10. Architecture Summary

**Architecture Type:** Layered, Component-Based

**Tier Structure:**

1. **Application Layer** (`main.zig`, `FirstApp.zig`, `Loop.zig`)
2. **Frame / Scene Layer** (`Renderer.zig`, `SimpleRenderSystem.zig`,
   `GameObject.zig`, `Model.zig`)
3. **High-Level Abstractions** (`Window.zig`, `Device.zig`,
   `Swapchain.zig`, `Pipeline.zig`)
4. **Vulkan Core Layer** (`Vulkan.zig`)
5. **FFI / Math / Utility Layer** (`c.zig` (GLFW / Vulkan),
   `math.zig`, `utils.zig`)
6. **Native Libraries** (GLFW, Vulkan SDK)

**Key Strengths:**

- Clear separation of concerns
- Modular component design
- Proper resource cleanup
- Type-safe Vulkan bindings
- Cross-platform support
- Enforced spell checking on docs + code via `codebook`

**Current Stage:** End-to-end rendering pipeline working — `FirstApp`
drives a `Renderer` + `SimpleRenderSystem` to draw a colored cube
`GameObject` every frame, with swapchain recreation handled by the
renderer. Next up: camera / view matrices, descriptor sets, indexed
draws and asset loading.
