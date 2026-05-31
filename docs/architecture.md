# Architecture Overview

High-level architecture, data flow, design patterns, and the project
directory tree. Detailed per-file component descriptions live in
[components.md](./components.md); rendering-pipeline specifics live in
[rendering-pipeline.md](./rendering-pipeline.md).

## Architecture Type

Layered, component-based.

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

## Component Overview

The engine follows a layered architecture with clear separation of
concerns. `main.zig` is just a thin entry point; the real application
lives in `FirstApp.zig`, which composes a window, device, loop,
renderer and a list of `GameObject`s, and drives them via a
`SimpleRenderSystem` inside its `run()` loop.

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
    ├── SimpleRenderSystem.zig (consumes FrameInfo per frame)
    │     └── Pipeline.zig (graphics pipeline, shader modules)
    ├── PointLightSystem.zig (camera-facing billboard for the point
    │                         light; no vertex buffers)
    │     └── Pipeline.zig
    ├── Buffer.zig (VkBuffer + memory wrapper; global UBO + staging)
    ├── Descriptors.zig (DescriptorSetLayout/Pool/Writer + Builders)
    ├── FrameInfo.zig (per-frame context bundle)
    ├── Camera.zig (projection + view matrices)
    ├── KeyboardMovementController.zig (drives a viewer GameObject
    │                                    from keyboard input)
    └── GameObject.zig (optional Model + TransformComponent + color)
              ↓
          Model.zig (owns vertex + optional index Buffer)
              ↓
          c.zig (GLFW / Vulkan FFI) + math.zig
              ↓
          External Libraries (GLFW, Vulkan)
```

## Data Flow

### Initialization Flow

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

### Runtime Flow (`FirstApp.run`)

```
uboBuffers: [MAX_FRAMES_IN_FLIGHT]Buffer
for ub in uboBuffers:
  ub = Buffer.init(device,
                   @sizeOf(GlobalUbo),
                   1,                    // one instance per buffer
                   UNIFORM_BUFFER_BIT,
                   HOST_VISIBLE_BIT,
                   1)                    // no per-instance offset alignment
  ub.map(VK_WHOLE_SIZE, 0)               // persistently mapped

// Build the global descriptor set layout (UNIFORM_BUFFER at binding 0,
// vertex stage) and one descriptor set per frame in flight pointing
// at the matching uboBuffers[i].
globalSetLayout = DescriptorSetLayout.Builder(alloc, device)
                      .addBinding(0, UNIFORM_BUFFER, VERTEX_STAGE_BIT, 1)
                      .build()

globalDescriptorSets: [MAX_FRAMES_IN_FLIGHT]VkDescriptorSet
for (set, i) in globalDescriptorSets:
  bufferInfo = uboBuffers[i].descriptorInfo(VK_WHOLE_SIZE, 0)
  DescriptorWriter(alloc, &globalSetLayout, &self.globalPool)
      .writeBuffer(0, &bufferInfo)
      .build(&set)

SimpleRenderSystem.init(renderer.getSwapChainRenderPass(),
                        globalSetLayout.getDescriptorSetLayout())
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
    frameInfo = FrameInfo{ frameIndex          = renderer.getFrameIndex(),
                           frameTime           = frameTime,
                           commandBuffer       = cb,
                           camera              = &camera,
                           globalDescriptorSet = globalDescriptorSets[frameInfo.frameIndex] }

    // update: write this frame's dedicated UBO buffer in whole.
    // Projection and view are now stored separately so the point-light
    // vertex shader can extract the camera basis from `view` to build
    // a camera-facing billboard.
    ubo = GlobalUbo{ projection = camera.projection, view = camera.view }
    uboBuffers[frameInfo.frameIndex].writeToBuffer(&ubo, VK_WHOLE_SIZE, 0)
    uboBuffers[frameInfo.frameIndex].flush(VK_WHOLE_SIZE, 0)

    // render
    renderer.beginSwapChainRenderPass(cb)
    simpleRenderSystem.renderGameObjects(&frameInfo)  // iterates frameInfo.gameObjects
    pointLightSystem.render(&frameInfo)               // 6-vertex billboard
    renderer.endSwapChainRenderPass(cb)
    renderer.endFrame()         // submits + presents
  // On error.SwapChainFormatChanged → rebuild both SimpleRenderSystem
  //   and PointLightSystem against the new render pass and continue.

vkDeviceWaitIdle(device)        // before deinit
```

## Design Patterns

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

## Error Handling

- Zig error union types (`!Type`)
- Try operator (`try`) for error propagation
- `checkSuccess()` converts Vulkan error codes to Zig errors
- Validation layer support for runtime errors

```zig
try checkSuccess(c.vkCreateDevice(...))  // Propagates errors
_ = c.vkEnumeratePhysicalDevices(...)    // Ignores result
```

## Memory Management

- Page allocator for main application lifetime
- ArrayList for dynamic collections
- Explicit deallocation with `defer`
- No garbage collection (manual management)

```zig
var extensions: std.ArrayList(...) = .empty;
defer extensions.deinit(alloc);
```

## Current Stage

End-to-end rendering pipeline working — `FirstApp` drives a
`Renderer` plus two render systems each frame:

1. `SimpleRenderSystem` draws two embedded Wavefront `.obj` vases on
   top of a quad "floor" with point-light + ambient lighting.
2. `PointLightSystem` then draws a 6-vertex camera-facing billboard
   at the light's world-space position (a small disc rendered from
   `gl_VertexIndex` lookups, no vertex buffers bound) so the light is
   visible in the scene.

Scene objects live in a `GameObject.Map`
(`AutoHashMapUnmanaged(u64, GameObject)`) owned by `FirstApp`, which
the simple render system iterates via a `*GameObject.Map` carried
through `FrameInfo`. The **projection** matrix, the **view** matrix
(now stored separately so the point-light vertex shader can extract
the camera basis from `view`), point-light position, light
color/intensity and ambient color/intensity are all delivered
through a per-frame global UBO bound at descriptor set 0, binding 0
(visible to `VK_SHADER_STAGE_ALL_GRAPHICS` because the fragment
shader took over the lighting). Only the simple render system's
per-object model + normal matrices still travel as push constants;
the point-light system uses no push constants — every per-frame
value its shader needs comes from the global UBO. Lighting is
evaluated per-pixel in the fragment shader (smoother highlights than
the previous per-vertex pass).

The `Pipeline.PipelineConfigInfo` now carries the vertex
binding/attribute description slices (defaulting to `Model.Vertex`'s
single binding) so render systems can override them — the
point-light system supplies empty slices because it generates its
vertices procedurally from `gl_VertexIndex`.

Next up: a scene-level light list and (eventually) texturing.

## Project Directory Structure

```
vulkan-engine/
├── build.zig              # Build configuration (Zig build system)
├── build.zig.zon          # Zig manifest/dependencies
├── flake.nix              # Nix development environment
├── flake.lock             # Pinned Nix inputs
├── README.md              # Basic project info
├── AGENTS.md              # Top-level agent guidance (entry point)
├── codebook.toml          # Codebook configuration
├── docs/                  # Detailed agent docs (referenced from AGENTS.md)
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
│   │                        #   cached `properties` (incl. limits),
│   │                        #   buffer / image / command-pool helpers,
│   │                        #   single-time command + copyBuffer
│   │                        #   helpers, pure-logic pickMemoryType
│   ├── Window.zig           # GLFW window management, surface creation
│   │                        #   and framebuffer-resize callback
│   ├── Swapchain.zig        # Swapchain, depth resources, render pass,
│   │                        #   framebuffers, synchronization, acquire /
│   │                        #   submit-present (MAX_FRAMES_IN_FLIGHT = 2)
│   ├── Renderer.zig         # High-level frame driver: owns the swapchain
│   │                        #   and per-frame command buffers, exposes
│   │                        #   beginFrame / beginSwapChainRenderPass /
│   │                        #   endSwapChainRenderPass / endFrame
│   ├── Pipeline.zig         # Graphics pipeline configuration & creation
│   ├── SimpleRenderSystem.zig # Pipeline + push-constant based renderer
│   │                          # that draws a list of GameObjects from
│   │                          # a FrameInfo bundle
│   ├── PointLightSystem.zig # Draws the point light as a camera-facing
│   │                        # billboard (6 vertices generated from
│   │                        # gl_VertexIndex, no vertex/push-constant
│   │                        # data — light pos/color come from the
│   │                        # global UBO)
│   ├── Buffer.zig           # Thin wrapper around a VkBuffer +
│   │                        #   VkDeviceMemory: map / unmap /
│   │                        #   writeToBuffer / flush / invalidate
│   │                        #   plus *Index variants for per-frame
│   │                        #   UBO slices aligned to a configurable
│   │                        #   minOffsetAlignment.
│   ├── FrameInfo.zig        # Per-frame context (frameIndex, frameTime,
│   │                        #   commandBuffer, camera, globalDescriptorSet)
│   │                        #   passed into the render systems each frame.
│   ├── Descriptors.zig      # Descriptor set layouts, pools and writers
│   │                        #   (DescriptorSetLayout / DescriptorPool /
│   │                        #   DescriptorWriter, each with a Builder).
│   ├── Model.zig            # Vertex + (optional) index buffer wrapper
│   │                        #   built via a `Builder` struct, uploaded
│   │                        #   through a host-visible staging buffer
│   │                        #   into a DEVICE_LOCAL buffer (both
│   │                        #   buffers are owned `Buffer` instances);
│   │                        #   defines `Vertex` (position + color +
│   │                        #   normal + uv) with binding / attribute
│   │                        #   descriptions.
│   │                        #   `Builder.loadModel` parses Wavefront
│   │                        #   OBJ data via the C++ tinyobjloader
│   │                        #   library (called through the C-ABI
│   │                        #   wrapper in `tinyobj_wrapper.cpp`).
│   │                        #   `createModelFromFile` is a convenience
│   │                        #   factory that builds a `Model` from
│   │                        #   in-memory OBJ bytes (typically
│   │                        #   `@embedFile`'d).
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
│   ├── wrapper/
│   │   └── tinyobj/         # C-ABI shim over the C++ tinyobjloader
│   │       ├── README.md    #   library, used by Model.zig's
│   │       ├── tinyobj_wrapper.h    #   Builder.loadModel via c.zig.
│   │       └── tinyobj_wrapper.cpp  #   See the directory README for
│   │                                #   the C++/C boundary rationale.
│   └── utils.zig            # Utility functions (Vulkan result checking)
├── shaders/               # GLSL shader source files
│   ├── shader.vert        # Vertex shader for SimpleRenderSystem
│   │                      #   (push-constant model + normal matrix;
│   │                      #   passes world-space position/normal +
│   │                      #   vertex color through to the fragment
│   │                      #   shader)
│   ├── shader.frag        # Fragment shader for SimpleRenderSystem
│   │                      #   (per-pixel point-light + ambient
│   │                      #   shading using the global UBO)
│   ├── point_light.vert   # Vertex shader for PointLightSystem
│   │                      #   (no vertex input; emits a 6-vertex
│   │                      #   camera-facing quad from
│   │                      #   gl_VertexIndex / OFFSETS lookup +
│   │                      #   ubo.lightPosition)
│   └── point_light.frag   # Fragment shader for PointLightSystem
│                          #   (discards pixels outside the unit
│                          #   disc, writes ubo.lightColor)
├── models/                # Wavefront .obj model assets (embedded at
│   │                      #   build time via embedAllModels())
│   ├── flat_vase.obj      # Default scene model (flat-shaded normals)
│   ├── smooth_vase.obj    # Default scene model (smoothed normals)
│   └── quad.obj           # Flat floor quad used in the default scene
├── test_runner.zig        # Custom Zig test runner
└── zig-out/               # Build output directory (generated)
```
