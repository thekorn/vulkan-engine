---
globs:
  - "shaders/**"
  - "src/Pipeline.zig"
  - "src/SimpleRenderSystem.zig"
  - "src/Renderer.zig"
  - "src/Swapchain.zig"
  - "src/FrameInfo.zig"
  - "src/Descriptors.zig"
  - "src/Buffer.zig"
---

# Vulkan Rendering Pipeline

Details for the rendering pipeline stages, shaders and key Vulkan
configuration. Loaded when editing shaders or the render-related Zig
sources.

## Pipeline Architecture

The rendering pipeline is structured in stages following the Vulkan
graphics pipeline model:

### 1. Instance & Device Setup

- Location: `Vulkan.zig` + `Device.zig`
- Creates Vulkan instance with platform-specific extensions
- Selects suitable physical device
- Creates logical device with graphics and presentation queues

### 2. Surface & Swapchain

- Location: `Window.zig` + `Swapchain.zig`
- Surface is created via `glfwCreateWindowSurface`.
- `Swapchain.zig` owns the swapchain, color/depth images, image views,
  the render pass, framebuffers and per-frame sync primitives. It
  supports recreation (e.g. on window resize) by passing in the
  previous swapchain as `oldSwapchain`.

### 3. Shader Compilation

- Location: `build.zig` + `shaders/`
- Build-time: `glslc` compiles every file under `shaders/` to SPIR-V.
- Runtime: SPIR-V is added as anonymous module imports and embedded via
  `@embedFile` in `SimpleRenderSystem.zig`.
- Files:
  - `shader.vert` - Vertex shader. Reads the global UBO at
    `set = 0, binding = 0` (`mat4 projectionViewMatrix` + `vec3
    directionToLight`), then uses push constants (`mat4 modelMatrix`
    + `mat4 normalMatrix`) to compute
    `gl_Position = ubo.projectionViewMatrix * push.modelMatrix * vec4(position, 1)`
    and the modulated ambient + directional diffuse vertex color.
  - `shader.frag` - Fragment shader (writes interpolated vertex color)

### 4. Graphics Pipeline & Render System

- Location: `Pipeline.zig` + `SimpleRenderSystem.zig`
- `Pipeline` owns the shader modules and the `VkPipeline`.
- `SimpleRenderSystem` owns the `VkPipelineLayout` (with one push
  constant range covering `SimplePushConstantData`) and the `Pipeline`,
  and is built against a render pass obtained from `Renderer`.

### 5. Frame Rendering

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

## Shader Details

### Vertex Shader (`shader.vert`)

```glsl
#version 450

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 color;
layout(location = 2) in vec3 normal;
layout(location = 3) in vec2 uv;

layout(location = 0) out vec3 fragColor;

layout(set = 0, binding = 0) uniform GlobalUbo {
    mat4 projectionViewMatrix;
    vec3 directionToLight;
} ubo;

layout(push_constant) uniform Push {
    mat4 modelMatrix;
    mat4 normalMatrix;
} push;

const float AMBIENT = 0.02;

void main() {
    gl_Position = ubo.projectionViewMatrix * push.modelMatrix * vec4(position, 1.0);

    vec3 normalWorldSpace = normalize(mat3(push.normalMatrix) * normal);
    float lightIntensity = AMBIENT + max(dot(normalWorldSpace, ubo.directionToLight), 0);

    fragColor = lightIntensity * color;
}
```

### Fragment Shader (`shader.frag`)

```glsl
#version 450

layout(location = 0) in  vec3 fragColor;
layout(location = 0) out vec4 outColor;

layout(push_constant) uniform Push {
    mat4 modelMatrix;
    mat4 normalMatrix;
} push;

void main() {
    outColor = vec4(fragColor, 1.0);
}
```

### Current State

Renders the two vase models (`flat_vase.obj` and `smooth_vase.obj`)
side-by-side as `GameObject`s driven by `SimpleRenderSystem`, lit by a
single directional light plus a small ambient term. The directional
light direction now comes from the per-frame `GlobalUbo` (bound via
descriptor set 0, binding 0) rather than a shader-side constant, and
`projection * view` is applied in the shader instead of being baked
into the push-constant transform.

## Key Configuration Parameters

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
