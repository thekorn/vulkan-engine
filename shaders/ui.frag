#version 450

layout(location = 0) in vec4 fragColor;
layout(location = 1) in vec2 fragLocalPos;
layout(location = 2) flat in vec2 fragHalfSize;
layout(location = 3) flat in float fragRadius;

layout(location = 0) out vec4 outColor;

// Signed distance to a rounded box centered at the origin. `p` is the
// sample position, `b` the box half-size and `r` the corner radius.
// Negative inside, positive outside.
float sdRoundedBox(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
  // Clamp the radius so it never exceeds half the shortest side.
  float r = min(fragRadius, min(fragHalfSize.x, fragHalfSize.y));
  float d = sdRoundedBox(fragLocalPos, fragHalfSize, r);

  // Anti-alias the edge over roughly one pixel using the screen-space
  // derivative of the distance field.
  float aa = max(fwidth(d), 1e-4);
  float coverage = 1.0 - smoothstep(-aa, aa, d);

  outColor = vec4(fragColor.rgb, fragColor.a * coverage);
}
