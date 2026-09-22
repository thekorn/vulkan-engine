# Vulkan Engine

A small Vulkan rendering engine written in Zig, built around a
layered architecture (swapchain, renderer and pluggable render
systems) that transparently handles window resizes and swapchain
recreation.

The project ships **two interchangeable application roots**;
[`src/main.zig`](src/main.zig) picks which one to run at build time via
the `-Dapp=` build option (see [`build.zig`](build.zig)):

- **`CustomUiApp`** (current default) — a minimal app demonstrating a
  custom **immediate-mode UI**: a nested flex-style screen-space panel
  drawn by [`src/systems/UiRenderSystem.zig`](src/systems/UiRenderSystem.zig),
  plus the Dear ImGui debug overlay. No 3D scene, camera or lighting.
- **`TutorialApp`** — the full 3D scene: it renders `GameObject`s (two
  ceramic vases on a flat quad "floor", lit by six colored point
  lights spinning around the scene and rendered as camera-facing
  billboards), with the camera driven by a WASD + QE + arrow-key
  keyboard controller. Model assets are loaded from Wavefront `.obj`
  files embedded at build time from the `models/` directory and parsed
  by the C++
  [tinyobjloader](https://github.com/tinyobjloader/tinyobjloader)
  library through a small C-ABI shim under
  [`src/wrapper/tinyobj/`](src/wrapper/tinyobj/) — see that
  directory's [`README.md`](src/wrapper/tinyobj/README.md) for the
  C↔C++ boundary rationale.

To switch between them, pass the `-Dapp=` build option:
`-Dapp=custom` (the default) runs `CustomUiApp`, `-Dapp=tutorial` runs
`TutorialApp` — e.g. `zig build run -Dapp=tutorial`.

## immediate-mode UI

[`src/systems/UiRenderSystem.zig`](src/systems/UiRenderSystem.zig) is a
small custom 2D overlay render system with an immediate-mode API: each
frame the caller resets the queue with `beginFrame()`, pushes filled
rectangles in pixel coordinates with `rect(x, y, w, h, color)` or builds
a per-frame nested row/column flex tree with container calls and
`flexRect(...)`, then records the draws with
`render(commandBuffer, extent)`. No retained widget state is kept
between frames. The pipeline binds no vertex buffers — the quad is
generated procedurally in
[`shaders/ui.vert`](shaders/ui.vert) from `gl_VertexIndex`, with the
per-rect position/size/color delivered as push constants — and uses
alpha blending with depth testing disabled so the UI always draws on
top.

## local development

Install [devenv](https://devenv.sh/getting-started/) (which uses Nix),
then enter the pinned development environment:

```
devenv shell
```

Or run a command directly:

```
devenv shell -- zig build run
```

## checks and coverage

Run the test suite, build-integrated
[`zlinter`](https://github.com/KurtWagner/zlinter) checks and spell
checker before pushing changes:

```bash
devenv shell -- zig build test --summary all
devenv shell -- zig build lint
devenv shell -- codebook-lsp lint --unique -s .
```

The spell-check step uses [`codebook`](https://github.com/blopker/codebook) and
respects the project dictionary in `codebook.toml`. CI runs all three checks as
part of the `build test` workflow.

Generate a self-contained HTML coverage report with
[`zcov`](https://github.com/ericsssan/zcov):

```bash
devenv shell -- zig-cov test --format=html --output=coverage.html --include=src/ -- --summary all
```

## tools

### lines of code

```
devenv shell -- cloc src shaders models docs
```

## resources

- [Vulkan Tutorial](https://vulkan-tutorial.com/)
- [vulkan game engine tutorials by Brendan Galea](https://www.youtube.com/playlist?list=PL8327DO66nu9qYVKLDmdLW_84-yE4auCR) with [source code](https://github.com/blurrypiano/littleVulkanEngine)
- [rift engine](https://github.com/aaronmahlke/rift-engine/tree/main)
