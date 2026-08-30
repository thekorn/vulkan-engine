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

Detailed build-system, development-environment, testing and CI
information. Always-on quick commands live in the top-level
`AGENTS.md`.

## Toolchain

The project uses Zig's build system and currently requires
`0.17.0-dev.1509+bb296ab9b`, the compiler revision supported by
[`zcov`](https://github.com/ericsssan/zcov). `build.zig.zon` enforces
that minimum and `flake.nix` selects the matching
`mitchellh/zig-overlay` package (`master-2026-07-29`). Do not update
the compiler independently of zcov.

`build.zig.zon` supplies three source dependencies:

- `cimgui` — generated C ABI for Dear ImGui and its GLFW/Vulkan
  backends.
- `imgui` — the Dear ImGui source tree. The build assembles it below
  cimgui with `addWriteFiles().addCopyDirectory(...)` so the cimgui
  relative includes resolve.
- [`zlinter`](https://github.com/KurtWagner/zlinter) — integrated into
  the build graph; it is not a separate executable in the dev shell.

## Build Features

- `compileAllShaders()` walks `shaders/` with `std.Io.Dir`, invokes
  `glslc` for each source, and exposes the generated SPIR-V as
  anonymous imports consumed by `@embedFile`.
- `embedAllModels()` and `embedAllTextures()` expose files under
  `models/` and `textures/` as anonymous imports keyed by basename.
- The executable links GLFW, Vulkan, tinyobjloader, libc and libc++;
  Linux also links OpenGL.
- `tinyobj_wrapper.cpp`, cimgui, Dear ImGui and the ImGui backends are
  compiled as C++. C declarations are translated once at build time
  with `addTranslateC`, then re-exported by `src/c.zig`.
- `-Dapp=custom` selects the default custom-UI application;
  `-Dapp=tutorial` selects the full 3D tutorial scene.

Common commands:

```bash
zig build
zig build run
zig build run -Dapp=tutorial
zig build test --summary all
zig build lint
```

## Development Setup

Nix is the supported setup:

```bash
nix develop
nix develop --command zig build run
```

The flake provides the pinned Zig compiler, `zig-cov`, codebook,
`cloc`, `glslc`, pkg-config, GLFW, Vulkan headers/loader/validation
layers, tinyobjloader and Linux OpenGL libraries. It also exports the
Nix target, dynamic linker and runtime library path needed by Zig's
LLVM linker in this environment.

The flake exposes a `vulkan-engine` package in addition to the dev
shell. Zig package dependencies are fetched through `zig.fetchDeps`,
and `autoPatchelfHook` makes the installed Linux executable use its
Nix runtime libraries.

Without Nix, install the exact Zig version above, build/install zcov,
and provide GLFW3, a Vulkan SDK, tinyobjloader, a C++ runtime and
`shaderc/glslc`.

## Required Checks

These commands form one logical test suite and must all pass before a
commit or PR:

```bash
nix develop --command zig build test --summary all
nix develop --command zig build lint
nix develop --command codebook-lsp lint --unique -s .
```

### Tests

Tests live beside their source and are aggregated by the bottom-level
test block in `src/main.zig`. Ordinary `zig build test` uses
`test_runner.zig` in simple mode for readable status and timing output.

### Linting with zlinter

`zig build lint` runs zlinter as a build dependency. The configured
rules are:

- `switch_case_ordering`
- `no_unused`
- `no_deprecated`
- `no_orelse_unreachable`

Rule selection is intentionally project-specific, as recommended by
zlinter. Its naming rules are not enabled because this codebase has an
established mixture of Zig snake_case and tutorial-derived camelCase
APIs; adopting them would be an unrelated repository-wide rename.
Fix all reported errors and warnings rather than suppressing them.

### Spell Checking with codebook

The dictionary is `codebook.toml`. `--unique` deduplicates findings and
`-s` produces compact CI output. Prefer correcting a typo; add a word
to the dictionary only when it is a legitimate technical term.

## Coverage with zcov

Generate a self-contained source-level HTML report with:

```bash
nix develop --command zig-cov test --format=html --output=coverage.html -- --summary all
```

`zig-cov test` invokes the normal test build with
`-Dcoverage=true` and supplies `-Dcoverage-rt=<zig-cov-rt.o>`.
`build.zig` follows zcov's integration contract by enabling LLVM,
fuzz counters and libc on the test artifact, then linking the runtime
object directly.

Two project-specific details are required:

- Coverage uses Zig's compiler-provided test runner because fuzz
  instrumentation depends on its build-runner ABI. Ordinary tests
  continue to use `test_runner.zig`.
- The linked C++ translation units disable trace-comparison, inline
  counter and PC-table sanitizer coverage. zcov covers Zig sources;
  allowing Zig's fuzz flag to instrument C++ would emit callbacks its
  runtime does not implement and mix incompatible PC tables.

On Linux under Nix, the coverage test link allows unresolved symbols
inside shared libraries; those symbols are supplied by the selected
Nix glibc at runtime.

The generated `coverage.html` is ignored by Git. Other supported zcov
formats include summary output (the default) and LCOV; see zcov's
README for its complete CLI.

## CI (`.github/workflows/ci.yaml`)

The GitHub Actions workflow runs on pushes and pull requests to
`main`:

1. Checkout and install Nix.
2. `nix flake check`.
3. Spell check.
4. `zig build lint`.
5. `zig build test --summary all`.
6. Generate `coverage.html` with zcov.
7. Upload that single HTML file as the `coverage-report` artifact.

The old baseline artifact, JSON comparison script and PR-comment
permissions are intentionally absent; zcov's self-contained report is
the coverage deliverable.

## File Summary

- `build.zig` — shaders/assets, C translation, executable, tests,
  zcov instrumentation and zlinter step.
- `build.zig.zon` — package metadata, exact Zig minimum and source
  dependencies.
- `flake.nix` / `flake.lock` — reproducible compiler, zcov build,
  system libraries, package and dev shell.
- `test_runner.zig` — ordinary test output; not used for fuzz-based
  coverage runs.
- `codebook.toml` — spelling dictionary and ignored generated/vendor
  paths.
