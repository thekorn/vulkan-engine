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

// Per-rect push constants. `offset` / `extent` are already in Vulkan
// normalized device coordinates ([-1, 1], +Y down), pre-computed on
// the CPU from the rectangle pixel coordinates and the current
// swapchain extent.
layout(push_constant) uniform Push {
  vec2 offset;
  vec2 extent;
  vec4 color;
} push;

void main() {
  vec2 pos = push.offset + OFFSETS[gl_VertexIndex] * push.extent;
  gl_Position = vec4(pos, 0.0, 1.0);
  fragColor = push.color;
}
