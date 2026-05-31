---
globs:
  - "shaders/**"
  - "src/Pipeline.zig"
  - "src/systems/**"
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
  `@embedFile` in `systems/SimpleRenderSystem.zig` and
  `systems/PointLightSystem.zig`.
- Files:
  - `shader.vert` - Vertex shader for `SimpleRenderSystem`. Reads
    `ubo.projection` and `ubo.view` (now stored separately) from
    the global UBO at `set = 0, binding = 0`, then uses push
    constants (`mat4 modelMatrix` + `mat4 normalMatrix`) to compute
    the world-space position (passed through as `fragPosWorld`),
    the world-space normal
    (`fragNormalWorld = normalize(mat3(normalMatrix) * normal)`)
    and the clip-space `gl_Position = projection * view * positionWorld`.
    The raw vertex `color` is forwarded unchanged as `fragColor` —
    lighting is no longer evaluated here.
  - `shader.frag` - Fragment shader for `SimpleRenderSystem`. Reads
    the full global UBO (`mat4 projection`, `mat4 view`,
    `vec4 ambientLightColor` (`w` is intensity), `vec3 lightPosition`,
    `vec4 lightColor` (`w` is intensity)) at `set = 0, binding = 0`.
    Using the interpolated `fragPosWorld` and `fragNormalWorld`, it
    computes a per-pixel point-light contribution with a
    `1 / distance²` attenuation, adds the ambient term and writes
    `(diffuse + ambient) * fragColor` to `outColor`.
  - `point_light.vert` - Vertex shader for `PointLightSystem`. Takes
    no vertex input; emits the six corners of a screen-aligned quad
    from `OFFSETS[gl_VertexIndex]`. Extracts the camera right /
    up vectors from the columns of `ubo.view`, scales them by
    `LIGHT_RADIUS` and offsets `ubo.lightPosition` to place a
    camera-facing billboard at the light's world position, then
    transforms it by `ubo.projection * ubo.view`. Forwards the
    quad-local `fragOffset` to the fragment shader.
  - `point_light.frag` - Fragment shader for `PointLightSystem`.
    Discards pixels with `length(fragOffset) >= 1.0` (so the quad is
    rasterized as a disc) and writes `vec4(ubo.lightColor.xyz, 1.0)`
    everywhere else.

### 4. Graphics Pipeline & Render Systems

- Location: `Pipeline.zig` + `systems/SimpleRenderSystem.zig` + `systems/PointLightSystem.zig`
- `Pipeline` owns the shader modules and the `VkPipeline`.
- `PipelineConfigInfo` now carries the vertex
  binding / attribute description slices so render systems can
  override them. Defaults point at `Model.Vertex`'s single binding.
- `SimpleRenderSystem` owns a `VkPipelineLayout` (with one push
  constant range covering `SimplePushConstantData`) and a `Pipeline`,
  built against a render pass obtained from `Renderer`.
- `PointLightSystem` owns a separate `VkPipelineLayout` (no push
  constants, just the global descriptor set at set 0) and a
  `Pipeline` built with empty binding / attribute descriptions so
  Vulkan accepts a draw with no vertex buffers bound.

### 5. Frame Rendering

- Location: `Renderer.zig` + `FirstApp.zig`
- `Renderer.beginFrame` acquires a swapchain image and starts recording
  the per-frame command buffer; `beginSwapChainRenderPass` begins the
  render pass with the current framebuffer, viewport and scissor.
- `SimpleRenderSystem.renderGameObjects(&frameInfo)` binds the
  pipeline, binds the per-frame global descriptor set, then iterates
  `frameInfo.gameObjects.valueIterator()`, uploading push constants
  and issuing draws per `GameObject` via its `Model`.
- `PointLightSystem.render(&frameInfo)` then binds its own pipeline
  and the same global descriptor set and issues a single 6-vertex
  draw (no vertex/index buffers).
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
layout(location = 1) out vec3 fragPosWorld;
layout(location = 2) out vec3 fragNormalWorld;

layout(set = 0, binding = 0) uniform GlobalUbo {
    mat4 projection;
    mat4 view;
    vec4 ambientLightColor; // w is intensity
    vec3 lightPosition;
    vec4 lightColor; // w is light intensity
} ubo;

layout(push_constant) uniform Push {
    mat4 modelMatrix;
    mat4 normalMatrix;
} push;

void main() {
    vec4 positionWorld = push.modelMatrix * vec4(position, 1.0);
    gl_Position = ubo.projection * ubo.view * positionWorld;
    fragNormalWorld = normalize(mat3(push.normalMatrix) * normal);
    fragPosWorld = positionWorld.xyz;
    fragColor = color;
}
```

### Fragment Shader (`shader.frag`)

```glsl
#version 450

layout (location = 0) in vec3 fragColor;
layout (location = 1) in vec3 fragPosWorld;
layout (location = 2) in vec3 fragNormalWorld;

layout (location = 0) out vec4 outColor;

layout(set = 0, binding = 0) uniform GlobalUbo {
    mat4 projection;
    mat4 view;
    vec4 ambientLightColor; // w is intensity
    vec3 lightPosition;
    vec4 lightColor; // w is light intensity
} ubo;

layout(push_constant) uniform Push {
    mat4 modelMatrix;
    mat4 normalMatrix;
} push;

void main() {
    vec3 directionToLight = ubo.lightPosition - fragPosWorld;
    float attenuation = 1.0 / dot(directionToLight, directionToLight); // distance squared

    vec3 lightColor = ubo.lightColor.xyz * ubo.lightColor.w * attenuation;
    vec3 ambientLight = ubo.ambientLightColor.xyz * ubo.ambientLightColor.w;
    vec3 diffuseLight = lightColor * max(dot(normalize(fragNormalWorld), normalize(directionToLight)), 0);
    outColor = vec4((diffuseLight + ambientLight) * fragColor, 1.0);
}
```

### Point-Light Vertex Shader (`point_light.vert`)

```glsl
#version 450

const vec2 OFFSETS[6] = vec2[](
  vec2(-1.0, -1.0),
  vec2(-1.0,  1.0),
  vec2( 1.0, -1.0),
  vec2( 1.0, -1.0),
  vec2(-1.0,  1.0),
  vec2( 1.0,  1.0)
);

layout (location = 0) out vec2 fragOffset;

layout(set = 0, binding = 0) uniform GlobalUbo {
    mat4 projection;
    mat4 view;
    vec4 ambientLightColor;
    vec3 lightPosition;
    vec4 lightColor;
} ubo;

const float LIGHT_RADIUS = 0.05;

void main() {
    fragOffset = OFFSETS[gl_VertexIndex];
    vec3 cameraRightWorld = vec3(ubo.view[0][0], ubo.view[1][0], ubo.view[2][0]);
    vec3 cameraUpWorld    = vec3(ubo.view[0][1], ubo.view[1][1], ubo.view[2][1]);

    vec3 positionWorld = ubo.lightPosition.xyz
        + LIGHT_RADIUS * fragOffset.x * cameraRightWorld
        + LIGHT_RADIUS * fragOffset.y * cameraUpWorld;

    gl_Position = ubo.projection * ubo.view * vec4(positionWorld, 1.0);
}
```

### Point-Light Fragment Shader (`point_light.frag`)

```glsl
#version 450

layout (location = 0) in vec2 fragOffset;
layout (location = 0) out vec4 outColor;

layout(set = 0, binding = 0) uniform GlobalUbo {
    mat4 projection;
    mat4 view;
    vec4 ambientLightColor;
    vec3 lightPosition;
    vec4 lightColor;
} ubo;

void main() {
    float dis = sqrt(dot(fragOffset, fragOffset));
    if (dis >= 1.0) {
        discard;
    }
    outColor = vec4(ubo.lightColor.xyz, 1.0);
}
```

### Current State

Renders the two vase models (`flat_vase.obj` and `smooth_vase.obj`)
side-by-side on top of a `quad.obj` floor as `GameObject`s — now
stored in a `GameObject.Map` keyed by id and iterated by
`SimpleRenderSystem` via `frameInfo.gameObjects.valueIterator()` —
lit by a single point light plus a small ambient term. The point
light itself is then drawn on top by `PointLightSystem` as a small
camera-facing disc at its world-space position, using a 6-vertex
billboard generated procedurally in the vertex shader (no vertex
buffers, no push constants).

`projection` and `view` are now stored separately in the per-frame
`GlobalUbo` (bound via descriptor set 0, binding 0 with
`VK_SHADER_STAGE_ALL_GRAPHICS`) so the point-light vertex shader
can extract the camera basis from `view`. Together with the
point-light position, color/intensity and ambient color/intensity
they cover every value the shaders read from the global UBO.

The vase vertex shader only computes clip-space position +
world-space normal/position; the **fragment shader** evaluates the
`1 / distance²` point-light attenuation per pixel, producing
smoother highlights than the previous per-vertex lighting.
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
