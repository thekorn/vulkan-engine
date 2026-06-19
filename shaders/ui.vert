#version 450

// Unit-quad corners (two triangles) emitted procedurally from
// `gl_VertexIndex` — no vertex buffers are bound for the UI pipeline.
// Each corner is in the [0, 1] range and is scaled/offset by the
// per-rect push constants below to position the quad in NDC.
const vec2 OFFSETS[6] = vec2[](
  vec2(0.0, 0.0),
  vec2(0.0, 1.0),
  vec2(1.0, 0.0),
  vec2(1.0, 0.0),
  vec2(0.0, 1.0),
  vec2(1.0, 1.0)
);

layout(location = 0) out vec4 fragColor;
// Pixel-space position relative to the rect center, used by the
// rounded-box SDF in the fragment shader.
layout(location = 1) out vec2 fragLocalPos;
// Half the rect size and the corner radius, both in pixels. `flat`
// because they are constant across the rect.
layout(location = 2) flat out vec2 fragHalfSize;
layout(location = 3) flat out float fragRadius;

// Per-rect push constants. `bounds.xy` (offset) / `bounds.zw` (extent)
// are already in Vulkan normalized device coordinates ([-1, 1], +Y
// down), pre-computed on the CPU from the rectangle pixel coordinates
// and the current swapchain extent. Offset and extent are packed into
// a single vec4 so the Zig-side `extern struct` matches this std430
// layout on every platform (a 2-component vector is 16-byte aligned on
// some targets). `params.xy` is the rect size in pixels and `params.z`
// the corner radius in pixels, used for rounded-corner anti-aliasing.
layout(push_constant) uniform Push {
  vec4 bounds;
  vec4 color;
  vec4 params;
} push;

void main() {
  vec2 corner = OFFSETS[gl_VertexIndex];
  vec2 pos = push.bounds.xy + corner * push.bounds.zw;
  gl_Position = vec4(pos, 0.0, 1.0);
  fragColor = push.color;

  vec2 size = push.params.xy;
  // Center-relative pixel coordinate: [-size/2, size/2].
  fragLocalPos = (corner - 0.5) * size;
  fragHalfSize = size * 0.5;
  fragRadius = push.params.z;
}
