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
    `ubo.projection` and `ubo.view` (stored separately) from the
    global UBO at `set = 0, binding = 0`, then uses push constants
    (`mat4 modelMatrix` + `mat4 normalMatrix`) to compute the
    world-space position (passed through as `fragPosWorld`), the
    world-space normal
    (`fragNormalWorld = normalize(mat3(normalMatrix) * normal)`)
    and the clip-space `gl_Position = projection * view * positionWorld`.
    Also transforms the object-space tangent by the model matrix's
    upper-3x3 and forwards it (together with the handedness sign
    from `tangent.w`) as `fragTangentWorld` so the fragment shader
    can build a TBN basis for normal mapping. The raw vertex
    `color` is forwarded unchanged as `fragColor` and the vertex
    `uv` as `fragUv` — lighting is no longer evaluated here.
  - `shader.frag` - Fragment shader for `SimpleRenderSystem`.
    Reads the full global UBO at `set = 0, binding = 0`:
    `mat4 projection`, `mat4 view`, `mat4 invView`,
    `vec4 ambientLightColor` (`w` is intensity),
    `PointLight pointLights[10]` (each `{ vec4 position; vec4 color }`,
    `color.w` is intensity) and `int numLights`. Samples two
    combined-image-samplers — `diffuseMap` at
    `set = 1, binding = 0` and `normalMap` at
    `set = 1, binding = 1`. Builds a world-space TBN basis from
    the interpolated normal, the Gram-Schmidt-re-orthogonalized
    tangent and the handedness sign, decodes the sampled tangent-
    space normal (`sampled * 2 - 1`) and rotates it into world
    space to obtain the perturbed `surfaceNormal`. Using the
    interpolated `fragPosWorld`, it recovers the camera
    world-space position as `ubo.invView[3].xyz`, seeds
    `diffuseLight` with the ambient term, then loops
    `for (int i = 0; i < ubo.numLights; i++)` accumulating each
    light's `1 / distance²`-attenuated diffuse contribution plus a
    Blinn-Phong specular term (half-angle `H = normalize(L + V)`,
    raised to the 512th power for a sharp highlight) before
    writing `(diffuseLight + specularLight) * fragColor *
    texture(diffuseMap, fragUv).rgb` to `outColor`. Objects without
    named textures get a 1×1 white diffuse + a 1×1 flat normal map
    (`(128, 128, 255)` → `+Z` in tangent space) so the codepath is
    uniform and their look is unchanged.
  - `point_light.vert` - Vertex shader for `PointLightSystem`. Takes
    no vertex input; emits the six corners of a screen-aligned quad
    from `OFFSETS[gl_VertexIndex]`. Extracts the camera right / up
    vectors from the columns of `ubo.view`, scales them by
    `push.radius` and offsets `push.position.xyz` to place a
    camera-facing billboard at the light's world position, then
    transforms it by `ubo.projection * ubo.view`. Forwards the
    quad-local `fragOffset` to the fragment shader.
  - `point_light.frag` - Fragment shader for `PointLightSystem`.
    Discards pixels with `length(fragOffset) >= 1.0` (so the quad is
    rasterized as a disc) and writes `vec4(push.color.xyz, 1.0)`
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
- `PointLightSystem` owns a separate `VkPipelineLayout` (the global
  descriptor set at set 0 plus a `PointLightPushConstants` range
  covering vertex + fragment stages) and a `Pipeline` built with
  empty binding / attribute descriptions so Vulkan accepts a draw
  with no vertex buffers bound.

### 5. Frame Rendering

- Location: `Renderer.zig` + `FirstApp.zig`
- `Renderer.beginFrame` acquires a swapchain image and starts recording
  the per-frame command buffer; `beginSwapChainRenderPass` begins the
  render pass with the current framebuffer, viewport and scissor.
- Before recording draw calls, `FirstApp.run` seeds a `GlobalUbo`
  with `camera.getProjection()` / `camera.getView()` and calls
  `pointLightSystem.update(&frameInfo, &ubo)` to fill in
  `ubo.pointLights[0 .. ubo.numLights]` from the scene's
  point-light game objects (also rotating them around `(0, -1, 0)`
  each frame).
- `SimpleRenderSystem.renderGameObjects(&frameInfo)` binds the
  pipeline, binds the per-frame global descriptor set, then iterates
  `frameInfo.gameObjects.valueIterator()`, uploading push constants
  and issuing draws per model-bearing `GameObject` via its `Model`.
- `PointLightSystem.render(&frameInfo)` then binds its own pipeline
  and the same global descriptor set, iterates the scene's
  point-light game objects, and for each one uploads a
  `PointLightPushConstants` (`{ position, color, radius }`) and
  issues a 6-vertex draw (no vertex/index buffers).
- `endSwapChainRenderPass` + `endFrame` submit the command buffer and
  present. Swapchain recreation is handled transparently; if the
  format changes, `Renderer` returns `error.SwapChainFormatChanged` so
  callers can rebuild their pipelines/render systems.

## Shader Details

All four shaders share the same `GlobalUbo` declaration at
`set = 0, binding = 0`. The block is shown once below and then
omitted from the per-file listings for brevity.

```glsl
struct PointLight {
    vec4 position; // w is ignored
    vec4 color;    // w is intensity
};

layout(set = 0, binding = 0) uniform GlobalUbo {
    mat4 projection;
    mat4 view;
    mat4 invView;           // camera-to-world; invView[3].xyz = camera position
    vec4 ambientLightColor; // w is intensity
    PointLight pointLights[10];
    int numLights;
} ubo;
```

The `PointLight pointLights[10]` array size must match
`FrameInfo.MAX_LIGHTS` on the Zig side. Only the first
`ubo.numLights` entries are read each frame; the rest are unused
padding.

### Vertex Shader (`shader.vert`)

```glsl
#version 450

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 color;
layout(location = 2) in vec3 normal;
layout(location = 3) in vec2 uv;
layout(location = 4) in vec4 tangent; // xyz = tangent direction, w = handedness sign

layout(location = 0) out vec3 fragColor;
layout(location = 1) out vec3 fragPosWorld;
layout(location = 2) out vec3 fragNormalWorld;
layout(location = 3) out vec2 fragUv;
layout(location = 4) out vec4 fragTangentWorld; // xyz world-space tangent, w handedness

// GlobalUbo at set = 0, binding = 0 (shown above)

layout(push_constant) uniform Push {
    mat4 modelMatrix;
    mat4 normalMatrix;
} push;

void main() {
    vec4 positionWorld = push.modelMatrix * vec4(position, 1.0);
    gl_Position = ubo.projection * ubo.view * positionWorld;
    fragNormalWorld = normalize(mat3(push.normalMatrix) * normal);
    vec3 tangentWorld = normalize(mat3(push.modelMatrix) * tangent.xyz);
    fragTangentWorld = vec4(tangentWorld, tangent.w);
    fragPosWorld = positionWorld.xyz;
    fragColor = color;
    fragUv = uv;
}
```

### Fragment Shader (`shader.frag`)

```glsl
#version 450

layout (location = 0) in vec3 fragColor;
layout (location = 1) in vec3 fragPosWorld;
layout (location = 2) in vec3 fragNormalWorld;
layout (location = 3) in vec2 fragUv;
layout (location = 4) in vec4 fragTangentWorld;

layout (location = 0) out vec4 outColor;

// GlobalUbo at set = 0, binding = 0 (shown above)

// Per-object material textures bound by `SimpleRenderSystem` from
// each `GameObject.textureDescriptorSet`. Objects without a named
// diffuse / normal texture get the 1×1 white / 1×1 flat-normal
// fallback respectively.
layout(set = 1, binding = 0) uniform sampler2D diffuseMap;
layout(set = 1, binding = 1) uniform sampler2D normalMap;

layout(push_constant) uniform Push {
    mat4 modelMatrix;
    mat4 normalMatrix;
} push;

void main() {
    // Reconstruct the world-space TBN basis: Gram-Schmidt
    // orthogonalize the tangent against the normal so non-uniform
    // scaling on the model matrix doesn't tilt the basis, then
    // recover the bitangent from the pre-computed handedness sign.
    vec3 N = normalize(fragNormalWorld);
    vec3 T = normalize(fragTangentWorld.xyz - N * dot(N, fragTangentWorld.xyz));
    vec3 B = cross(N, T) * fragTangentWorld.w;
    mat3 TBN = mat3(T, B, N);

    // Decode the tangent-space normal (RGB 0..1 -> -1..1) and rotate
    // it into world space.
    vec3 sampledNormalTS = texture(normalMap, fragUv).xyz * 2.0 - 1.0;
    vec3 surfaceNormal = normalize(TBN * sampledNormalTS);

    vec3 diffuseLight = ubo.ambientLightColor.xyz * ubo.ambientLightColor.w;
    vec3 specularLight = vec3(0.0);

    vec3 cameraPosWorld = ubo.invView[3].xyz;
    vec3 viewDirection = normalize(cameraPosWorld - fragPosWorld);

    for (int i = 0; i < ubo.numLights; i++) {
        PointLight light = ubo.pointLights[i];
        vec3 directionToLight = light.position.xyz - fragPosWorld;
        float attenuation = 1.0 / dot(directionToLight, directionToLight); // distance squared
        directionToLight = normalize(directionToLight);

        float cosAngIncidence = max(dot(surfaceNormal, directionToLight), 0);
        vec3 intensity = light.color.xyz * light.color.w * attenuation;

        diffuseLight += intensity * cosAngIncidence;

        // specular lighting (Blinn-Phong half-angle)
        vec3 halfAngle = normalize(directionToLight + viewDirection);
        float blinnTerm = pow(clamp(dot(surfaceNormal, halfAngle), 0, 1), 512.0);
        specularLight += intensity * blinnTerm;
    }

    vec3 materialColor = fragColor * texture(diffuseMap, fragUv).rgb;
    outColor = vec4((diffuseLight + specularLight) * materialColor, 1.0);
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

// GlobalUbo at set = 0, binding = 0 (shown above)

layout(push_constant) uniform Push {
    vec4 position;
    vec4 color;
    float radius;
} push;

void main() {
    fragOffset = OFFSETS[gl_VertexIndex];
    vec3 cameraRightWorld = vec3(ubo.view[0][0], ubo.view[1][0], ubo.view[2][0]);
    vec3 cameraUpWorld    = vec3(ubo.view[0][1], ubo.view[1][1], ubo.view[2][1]);

    vec3 positionWorld = push.position.xyz
        + push.radius * fragOffset.x * cameraRightWorld
        + push.radius * fragOffset.y * cameraUpWorld;

    gl_Position = ubo.projection * ubo.view * vec4(positionWorld, 1.0);
}
```

### Point-Light Fragment Shader (`point_light.frag`)

```glsl
#version 450

layout (location = 0) in vec2 fragOffset;
layout (location = 0) out vec4 outColor;

// GlobalUbo at set = 0, binding = 0 (shown above)

layout(push_constant) uniform Push {
    vec4 position;
    vec4 color;
    float radius;
} push;

const float M_PI = 3.1415926538;

void main() {
    float dis = sqrt(dot(fragOffset, fragOffset));
    if (dis >= 1.0) {
        discard;
    }

    // Cosine fall-off from the center (1.0) to the rim (0.0). Used
    // for both a soft additive bloom on the color *and* the alpha,
    // so the disc fades out smoothly against the scene.
    float cosDis = 0.5 * (cos(dis * M_PI) + 1.0);
    outColor = vec4(push.color.xyz + 0.5 * cosDis, cosDis);
}
```

### Current State

Renders the two vase models (`flat_vase.obj` and `smooth_vase.obj`)
side-by-side on top of a `quad.obj` floor as `GameObject`s — stored
in a `GameObject.Map` keyed by id and iterated by
`SimpleRenderSystem` via `frameInfo.gameObjects.valueIterator()` —
lit by up to `MAX_LIGHTS = 10` point lights plus a small ambient
term. The default scene wires up six colored point lights arranged
in a circle around the origin, which `PointLightSystem.update()`
spins around the world's Y axis once per frame. Each point light is
also drawn on top by `PointLightSystem.render()` as a small
camera-facing disc at its world-space position — one 6-vertex
billboard draw per light, generated procedurally in the vertex
shader (no vertex buffers; the light's `position`, `color` and
`radius` come in via per-draw push constants).

`projection` and `view` are stored separately in the per-frame
`GlobalUbo` (defined in `FrameInfo.zig`; bound via descriptor set
0, binding 0 with `VK_SHADER_STAGE_ALL_GRAPHICS`) so the
point-light vertex shader can extract the camera basis from `view`.
Together with `ambientLightColor`, the `pointLights[10]` array and
`numLights`, that covers every value the shaders read from the
global UBO.

The vase vertex shader only computes clip-space position +
world-space normal/position; the **fragment shader** loops over
`ubo.pointLights[0 .. ubo.numLights]` and evaluates each light's
`1 / distance²`-attenuated diffuse contribution per pixel, plus a
Blinn-Phong specular term using the camera position recovered
from `ubo.invView[3].xyz`. `projection * view` is applied in the
shader instead of being baked into the push-constant transform.

The floor quad samples `stonefloor01_color_rgba.ktx` (diffuse)
together with its matching `stonefloor01_normal_rgba.ktx`
(tangent-space normal map) via two `COMBINED_IMAGE_SAMPLER`s bound
at `set = 1, binding = 0` and `set = 1, binding = 1` (the
`diffuseMap` / `normalMap` declarations in `shader.frag`).
`FirstApp.run` allocates one descriptor set per renderable
`GameObject` out of `globalPool`, filling binding 0 with the
object's `textureName` (defaulting to `"__default_white__"`) and
binding 1 with its `normalName` (defaulting to
`"__default_flat_normal__"`, which decodes to the tangent-space
`+Z` unit vector — i.e. "no perturbation"). The chosen set is
stamped onto each object's `textureDescriptorSet` so the shader
path is uniform across textured and untextured objects, and
`SimpleRenderSystem.renderGameObjects` binds it per draw before
the push constants.

Tangents for normal mapping are generated by
`Model.Builder.computeTangents` (a Lengyel-style per-triangle
accumulation plus Gram-Schmidt orthogonalization) and uploaded as
a fifth `Vec4` vertex attribute (`xyz` direction plus handedness
sign in `w`).

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

- Default: disabled (used by `SimpleRenderSystem`).
- `PointLightSystem` opts in via `Pipeline.enableAlphaBlending`,
  which switches the attachment to standard "source over" alpha
  blending: `srcColor=SRC_ALPHA`, `dstColor=ONE_MINUS_SRC_ALPHA`,
  `srcAlpha=ONE`, `dstAlpha=ZERO`, both blend ops = `ADD`. Combined
  with the cosine fall-off in `point_light.frag`, this gives soft
  fading billboards; the system therefore sorts lights
  back-to-front (by squared distance to
  `camera.getPosition()`) before drawing.
- RGBA write mask: All channels enabled.

**Depth Stencil:**

- Depth test: Enabled
- Depth write: Enabled
- Depth compare op: Less
- Stencil test: Disabled
