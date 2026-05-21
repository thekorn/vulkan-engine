# Vulkan Engine

## local development

Setup using nix

```
nix develop
```

Or even

```
nix develop --command zig build run
```

## tools

### lines of code

```
nix develop --command cloc src shaders
      14 text files.
      14 unique files.
       0 files ignored.

github.com/AlDanial/cloc v 2.08  T=0.01 s (1393.9 files/s, 318794.2 lines/s)
-------------------------------------------------------------------------------
Language                     files          blank        comment           code
-------------------------------------------------------------------------------
Zig                             12            469            173           2533
GLSL                             2              6              0             21
-------------------------------------------------------------------------------
SUM:                            14            475            173           2554
-------------------------------------------------------------------------------
```

## resources

- [Vulkan Tutorial](https://vulkan-tutorial.com/)
- [vulkan game engine tutorials by Brendan Galea](https://www.youtube.com/playlist?list=PL8327DO66nu9qYVKLDmdLW_84-yE4auCR) with [source code](https://github.com/blurrypiano/littleVulkanEngine)
- [rift engine](https://github.com/aaronmahlke/rift-engine/tree/main)
