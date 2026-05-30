# Vulkan Engine — Agent Guidance

A small Vulkan rendering engine written in Zig 0.16, built on GLFW +
Vulkan + a C-ABI shim over `tinyobjloader`. Entry point is
[`src/main.zig`](src/main.zig), which hands off to
[`src/FirstApp.zig`](src/FirstApp.zig).

Detailed guidance is split into focused docs under `docs/`:

- @docs/architecture.md — always-on: high-level architecture,
  data flow, design patterns, directory tree.
- @docs/development-notes.md — always-on: platform notes, known
  limitations & TODOs.
- @docs/components.md — loaded when editing files under `src/`:
  per-module reference for every Zig file in the project.
- @docs/rendering-pipeline.md — loaded when editing shaders or
  render-related Zig sources: Vulkan pipeline stages, shader
  source, and pipeline configuration.
- @docs/build-and-tooling.md — loaded when editing `build.zig*`,
  `flake.nix`, `codebook.toml`, `test_runner.zig` or anything under
  `.github/`: full build / dev-env / CI / testing details.

## Required Checks Before Committing

These three commands form one logical "test suite" — all must pass
before committing or opening a PR. CI runs the same commands.

```bash
nix develop --command zig build test --summary all   # build + Zig tests
nix develop --command codebook-lsp lint --unique -s . # spell check
nix develop --command zlint src/*                    # Zig lint
```

When the spell checker flags a legitimate technical term, add it to
the `words` array in `codebook.toml` rather than rewording. For
`zlint`'s `unsafe-undefined`, prefer fixing the diagnostic; otherwise
add a `// SAFETY: <reason>` comment above the line.

## Quick Commands

```bash
nix develop                       # enter the dev shell (recommended)
zig build                         # compile
zig build run                     # compile and run
zig build test                    # run the Zig test suite
zig build coverage                # kcov coverage report (Linux only)
zig build test -Dcover -Dopen     # run under kcov and open the HTML report
zig build --help                  # show all options
```

Without Nix, install Zig 0.16.0, GLFW3, the Vulkan SDK and
`shaderc/glslc` manually.

## Key File Locations

- Entry point: [`src/main.zig`](src/main.zig)
- Application root: [`src/FirstApp.zig`](src/FirstApp.zig)
- Shader sources: [`shaders/`](shaders/)
- Build config: [`build.zig`](build.zig)
- Custom test runner: [`test_runner.zig`](test_runner.zig)
- Spell-check dictionary: [`codebook.toml`](codebook.toml)
- Dev environment: [`flake.nix`](flake.nix)

## Graceful Shutdown

The main loop installs `SIGINT` / `SIGTERM` / `SIGHUP` handlers
(POSIX only). Use `kill -INT <pid>` or `pkill vulkan_engine` to close
the app cleanly. Avoid `kill -9` / `SIGKILL`; it bypasses Vulkan and
GLFW cleanup.
