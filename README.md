# Vulkan Engine

A small Vulkan rendering engine written in Zig. It renders 3D
`GameObject`s (currently a single indexed, colored cube) through a
layered architecture built around a swapchain, renderer and pluggable
render systems. The renderer transparently handles window resizes and
swapchain recreation, and the camera is driven by a WASD + QE +
arrow-key keyboard controller.

## local development

Setup using nix

```
nix develop
```

Or even

```
nix develop --command zig build run
```

## tests & spell checking

Run the test suite **and** the spell checker before pushing changes:

```
nix develop --command zig build test --summary all
nix develop --command codebook-lsp lint --unique -s .
```

The spell-check step uses [`codebook`](https://github.com/blopker/codebook) and
respects the project dictionary in `codebook.toml`. CI runs both steps as part
of the `build test` workflow.

## tools

### lines of code

```
nix develop --command cloc src shaders
```

## resources

- [Vulkan Tutorial](https://vulkan-tutorial.com/)
- [vulkan game engine tutorials by Brendan Galea](https://www.youtube.com/playlist?list=PL8327DO66nu9qYVKLDmdLW_84-yE4auCR) with [source code](https://github.com/blurrypiano/littleVulkanEngine)
- [rift engine](https://github.com/aaronmahlke/rift-engine/tree/main)
