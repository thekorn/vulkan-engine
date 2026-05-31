# Development Notes

Platform-specific considerations, known limitations / TODOs, and
references the project is based on. Always loaded — small enough to
keep in context for orientation.

## Platform-Specific Considerations

**macOS Support:**

- Handles `VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME`
- Requires `VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME`
- Portability subset extension required

**Linux Support:**

- Includes GL library linking
- Tested in CI pipeline

## Known Limitations & TODOs

- Validation layer cleanup incomplete — debug messenger destruction is
  TODO (see `Device.deinit`).
- Only a small hardcoded scene (two `.obj`-loaded vases sitting on a
  flat quad "floor" wired up in `FirstApp.loadGameObjects`).
- Lighting is a single point light + constant ambient term. The
  point-light position, color/intensity and ambient color/intensity
  now come from the per-frame `GlobalUbo`, but the values are still
  set once at startup (`GlobalUbo` defaults) rather than driven by a
  scene-level light list. Lighting is now evaluated per-pixel in
  `shader.frag` (the vertex shader only emits world-space position
  and normal); the next big lighting step is multiple lights.
- The shader still ignores `uv` (uploaded to the GPU but unused), so
  there is no texturing.
- The OBJ loader uses tinyobjloader through a thin C-ABI wrapper, but
  ignores materials (`mtllib` / `usemtl`) and only forwards the
  attributes consumed by `Vertex`.

## Extension References

- Based on Vulkan Tutorial (vulkan-tutorial.com)
- Inspired by Little Vulkan Engine by Brendan Galea
- Related projects: rift-engine
