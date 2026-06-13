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

// Per-rect push constants. `bounds.xy` (offset) / `bounds.zw` (extent)
// are already in Vulkan normalized device coordinates ([-1, 1], +Y
// down), pre-computed on the CPU from the rectangle pixel coordinates
// and the current swapchain extent. Offset and extent are packed into
// a single vec4 so the Zig-side `extern struct` matches this std430
// layout on every platform (a 2-component vector is 16-byte aligned on
// some targets).
layout(push_constant) uniform Push {
  vec4 bounds;
  vec4 color;
} push;

void main() {
  vec2 pos = push.bounds.xy + OFFSETS[gl_VertexIndex] * push.bounds.zw;
  gl_Position = vec4(pos, 0.0, 1.0);
  fragColor = push.color;
}
