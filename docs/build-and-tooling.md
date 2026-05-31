---
globs:
  - "build.zig"
  - "build.zig.zon"
  - "flake.nix"
  - "flake.lock"
  - "codebook.toml"
  - ".github/**"
  - "test_runner.zig"
---

# Build, Tooling & CI

Detailed build-system, dev-environment, testing and CI information.
Loaded when editing build configuration, Nix files, the spell-check
dictionary, the test runner, or anything under `.github/`. Always-on
quick commands live in the top-level `AGENTS.md`.

## Build System

**Build System:** Zig Build System

- **Language:** Zig (systems programming language)
- **Minimum Version:** 0.16.0
- **Files:**
  - `build.zig` - Main build configuration
  - `build.zig.zon` - Zig dependency manifest. Pulls in:
    - `cimgui` (`https://github.com/cimgui/cimgui`) — auto-generated
      C-ABI wrapper around Dear ImGui, plus C-ABI bindings for the
      GLFW + Vulkan backends (`cimgui_impl.cpp` / `cimgui_impl.h`).
    - `imgui` (`https://github.com/ocornut/imgui`) — the Dear ImGui
      source tree itself. cimgui normally pulls this in as a git
      submodule; we fetch it as a separate tarball and then
      assemble both into a synthetic source tree via
      `b.addWriteFiles().addCopyDirectory(...)` so the
      `#include "./imgui/imgui.h"` lines inside cimgui resolve.

### Build Features

- **Shader Compilation:** Automatic GLSL to SPIR-V compilation using `glslc`
  - Shaders are discovered by walking `shaders/` via `std.Io.Dir` (Zig 0.16 std.Io API)
  - Compiled outputs are added as anonymous module imports and embedded via `@embedFile` in `main.zig`
  - Located in `compileAllShaders()` function
- **Model Asset Embedding:** Wavefront `.obj` files under `models/`
  are added as anonymous module imports keyed by their basename (e.g.
  `smooth_vase.obj`), so call sites can use `@embedFile`. Located in
  the `embedAllModels()` function.
- **Texture Asset Embedding:** Mirror of model embedding for
  texture files under `textures/` (currently a single
  `stonefloor01_color_rgba.ktx`). Each file is registered as an
  anonymous import keyed by basename so `Texture.initFromKtxBytes`
  can pull the bytes via `@embedFile`. Located in the
  `embedAllTextures()` function.
- **System Library Linking:**
  - `glfw3` - Window and input management
  - `vulkan` - Vulkan API
  - `tinyobjloader` - Wavefront OBJ loader (used through a small
    C-ABI wrapper compiled from `src/wrapper/tinyobj/tinyobj_wrapper.cpp`)
  - `gl` - On Linux only
- **C++ Wrapper Compilation:** `build.zig` compiles two C++ surfaces
  into the executable, with `link_libc` + `link_libcpp` enabled on
  every platform:
  - `src/wrapper/tinyobj/tinyobj_wrapper.cpp` — a thin C-ABI wrapper
    around the C++ tinyobjloader API (see
    `src/wrapper/tinyobj/README.md` for the rationale).
  - cimgui + Dear ImGui (`cimgui.cpp`, `cimgui_impl.cpp`,
    `imgui/imgui.cpp`, `imgui/imgui_draw.cpp`,
    `imgui/imgui_demo.cpp`, `imgui/imgui_tables.cpp`,
    `imgui/imgui_widgets.cpp`, `imgui/backends/imgui_impl_glfw.cpp`,
    `imgui/backends/imgui_impl_vulkan.cpp`) — fetched as remote
    `build.zig.zon` dependencies and assembled into a single
    synthetic source tree via `b.addWriteFiles()` before compilation.
    Compiled with `-DCIMGUI_USE_GLFW`, `-DCIMGUI_USE_VULKAN`,
    `-DIMGUI_IMPL_API=extern "C"` (so the backend C++ functions get
    C linkage that matches the `extern "C"` declarations in
    `cimgui_impl.h`) and `-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS` (to
    suppress a single legacy `ImGui_ImplVulkan_AddTexture` overload
    that C linkage cannot represent).
- **Test Infrastructure:** Built-in test support via `zig build test`

### Build Commands

```bash
zig build              # Build executable
zig build run          # Build and run
zig build test         # Run tests
zig build coverage     # Run tests under kcov, write report to zig-out/cover (Linux only)
zig build test -Dcover -Dopen   # Run tests under kcov and open the HTML report
```

Whenever kcov runs (via either `zig build coverage` or `zig build test
-Dcover`), a compact summary is printed at the end of the terminal
output: an overall percentage followed by a per-file breakdown sorted
worst-first. It reads the per-run `coverage.json` produced by kcov via
`jq`, so `jq` must be on `PATH` (provided by the Nix dev shell).

## Development Setup

Two options for local development:

**Option 1 — Nix (Recommended):**

```bash
nix develop
nix develop --command zig build run
```

**Option 2 — Manual Setup:** install the required dependencies:

- Zig 0.16.0
- GLFW3
- Vulkan SDK
- shaderc/glslc (for shader compilation)

### Nix Dev Environment (`flake.nix`)

- Nix package manager configuration
- Provides reproducible development environment
- Dependencies:
  - `zig_0_16` - Compiler
  - `zls_0_16` - Language server
  - `zig-zlint` - Zig linter (`zlint` binary)
  - `codebook` - Spell checker (`codebook-lsp` binary)
  - `cloc` - Lines-of-code report
  - `jq` - JSON formatter, used by the coverage summary printer in
    `build.zig`
  - `shaderc` - Shader compilation
  - `vulkan-headers`, `vulkan-loader(.dev)`, `vulkan-validation-layers`
  - `tinyobjloader` - Wavefront OBJ loader (C++); pkg-config supplies
    the include path and static archive consumed by
    `src/wrapper/tinyobj/tinyobj_wrapper.cpp`
  - `glfw` - Window system
  - `pkg-config` - Dependency discovery
  - Platform-specific: `libGL(.dev)` on Linux
- Sets `VK_LAYER_PATH` to the validation layers from `vulkan-validation-layers`.

## Spell Checking (codebook)

The project uses [`codebook`](https://github.com/blopker/codebook) for
spell-checking source and documentation. The project dictionary lives in
`codebook.toml`.

Always run the spell checker together with the test suite:

```bash
nix develop --command codebook-lsp lint --unique -s .
```

The `--unique` flag deduplicates findings and `-s` makes the output
suitable for scripts / CI logs. When introducing a new word, prefer
fixing the typo; if the word is a legitimate technical term, add it to
the `words` array in `codebook.toml`.

CI (see `.github/workflows/ci.yaml`) runs both `codebook-lsp lint .` and
`zig build test`; treat the spell check as a required part of "running
the tests".

## Linting (zlint)

The project uses [`zlint`](https://github.com/DonIsaac/zlint) (packaged
in nixpkgs as `zig-zlint`) as a Zig-aware linter. It catches issues
like unused declarations, unsafe `undefined` usage without a `SAFETY:`
comment and `std.debug.print` calls in non-debug code.

Run alongside the tests and spell checker:

```bash
nix develop --command zlint src/*
```

`zlint` walks the current directory by default, so just run it from the
repo root. CI runs the same `nix develop -c zlint` invocation as a
dedicated step in `.github/workflows/ci.yaml`. Warnings currently do not
fail the build (no `--deny-warnings`), but treat any new lint warning
you introduce as something to fix before committing — either by
addressing the diagnostic or, for `unsafe-undefined`, by adding a
`// SAFETY: <reason>` comment above the line.

## Testing

**Testing Framework:**

- Built into Zig language
- Uses `@import("builtin")` for compile-time checks
- Test declarations with `test` keyword
- Custom runner: `test_runner.zig` (`mode = .simple`)

**Current Test Setup:**

- Located in: individual source files; all aggregated via the `test {}`
  block at the bottom of `src/main.zig` (which `_ = @import`s every
  module so their tests are discovered).
- Test execution: `zig build test`
- CI integration: GitHub Actions runs tests on every PR/push.

**Running Tests (always run the spell checker and linter alongside!):**

```bash
zig build test                                   # Local testing
zig build test --summary all                     # Detailed summary
nix develop -c zig build test --summary all      # In Nix environment

# Spell check — REQUIRED part of "running the tests":
nix develop --command codebook-lsp lint --unique -s .

# Lint — REQUIRED part of "running the tests":
nix develop --command zlint src/*
```

**Notable Test Features:**

- No external test framework required (Zig built-in)
- Tests run at compile time when possible
- Can be run in debug and release modes
- Spell checking and `zlint` are treated as required checks,
  equivalent in importance to the Zig test suite.

## CI/CD Configuration (`.github/workflows/ci.yaml`)

- GitHub Actions workflow
- Triggers on PR and push to main
- Runs on Ubuntu Linux
- Steps:
  1. Checkout repository
  2. Install Nix (Determinate Systems installer + magic Nix cache)
  3. Run `nix flake check`
  4. Spell check: `nix develop -c codebook-lsp lint .`
  5. Lint: `nix develop -c zlint`
  6. Build & tests: `nix develop -c zig build test --summary all`
  7. Coverage: `nix develop -c zig build coverage --summary all`
  8. Upload the full HTML report as the `coverage-report` artifact
  9. On `push` to `main`: upload `coverage.json` (via the stable
     `zig-out/cover/test/` symlink kcov maintains) as the
     `coverage-main` artifact so PRs can diff against it
  10. On `pull_request`: download the latest `coverage-main` artifact
      from `main` and post a sticky PR comment with the overall
      coverage and the per-file delta vs `main` (via
      `actions/github-script`).
- Concurrency control to cancel outdated runs
- The PR comment uses `<!-- coverage-comment -->` as a marker so it is
  updated in place on subsequent pushes instead of accumulating.

## Git Configuration

**.gitignore**

- Ignores: `zig-out/`, `.zig-cache/`, `zig-pkg/` (Zig 0.16+ local
  package fetch cache, populated by `build.zig.zon` deps such as
  cimgui / Dear ImGui)
- Allows: source code (including the in-tree `*.cpp` / `*.h`
  wrapper under `src/wrapper/tinyobj/`), build files, configuration

## Build Config Files (summary)

**build.zig**

- Zig build system configuration
- Handles shader compilation (`glslc` per file under `shaders/`)
- Links system libraries (`glfw3`, `vulkan`; `gl` on Linux)
- Defines build steps (`run`, `test`)
- Uses a custom test runner (`test_runner.zig`, simple mode)
- Target and optimization settings

**build.zig.zon**

- Package metadata
- Project name: `vulkan_engine`
- Version: 0.0.0
- Minimum Zig version: 0.16.0
- Dependencies: None (using system libraries)
