# `tinyobj_wrapper` — why this directory exists

This directory is a thin **C-ABI shim** over the C++
[tinyobjloader](https://github.com/tinyobjloader/tinyobjloader)
library, so the rest of the engine (written in Zig) can use it through
`@cImport`.

It boils down to **what `@cImport` can translate** vs. **what the
tinyobjloader API actually is**.

## tinyobjloader is a C++ library, not C

Its public header (`tiny_obj_loader.h`) exposes its API through C++
types:

```cpp
bool LoadObj(attrib_t *attrib,
             std::vector<shape_t> *shapes,
             std::vector<material_t> *materials,
             std::string *warn,
             std::string *err,
             std::istream *inStream, ...);
```

That signature uses `std::vector`, `std::string`, `std::istream` — and
the `attrib_t` / `shape_t` structs themselves contain
`std::vector<float>`, `std::vector<index_t>`, etc.

## The Zig `@cImport` builtin only handles C

`@cImport` runs the input through a **C translator** (arocc in Zig
0.16). It only understands C declarations. When it hits C++ constructs
— templates, `std::vector`, name-mangled overloads, RTTI, exceptions —
it either skips them or fails outright. There's no way to say
`@cImport("tiny_obj_loader.h")` and get back something usable from Zig.
Zig has no C++ frontend or ABI of its own.

## Even if we could call it, the types don't cross the boundary

Calling `std::vector<float>::operator[]` from Zig would require knowing
the layout of `std::vector` from libc++ / libstdc++ (which is
implementation-defined and version-dependent), invoking its
constructors/destructors correctly, dealing with name-mangled methods,
and linking against the C++ runtime. Nobody does this — it would be
brittle and non-portable.

## The standard fix: a C-ABI shim

The universal pattern for using C++ from a non-C++ language (Zig, Rust,
Go, Python, ...) is:

```diagram
╭─────────╮   plain C    ╭─────────────────╮   C++    ╭───────────────╮
│  Zig    │ ───────────▶ │ extern "C" shim │ ───────▶ │ C++ library   │
│         │  (function   │  • translates   │  (uses   │  (std::vector,│
│         │   pointers,  │    C++ types    │   STL    │   templates,  │
│         │   structs of │    to plain     │   freely)│   etc.)       │
│         │   primitives)│    C primitives │          │               │
╰─────────╯              ╰─────────────────╯          ╰───────────────╯
```

That's exactly what
[`tinyobj_wrapper.cpp`](tinyobj_wrapper.cpp) is. It:

1. Accepts a `(const char*, size_t)` buffer instead of `std::istream*`.
2. Internally creates a `std::istringstream` and calls
   `tinyobj::LoadObj`.
3. Walks the resulting `std::vector<shape_t>` and deduplicates
   vertices with a `std::unordered_map` — all of this happens
   **inside** the C++ translation unit where STL is fair game.
4. Copies the final results into `malloc`-allocated flat arrays of
   `tinyobj_wrapper_vertex` and `uint32_t`.
5. Returns through pointer-to-pointer out-parameters and an integer
   status — primitives only.

The matching [`tinyobj_wrapper.h`](tinyobj_wrapper.h) is a pure C
header (only `<stddef.h>` and `<stdint.h>` types, wrapped in
`extern "C"`), so `@cImport` can translate it cleanly and Zig sees
ordinary function prototypes.

## Wiring it up

The build system (`build.zig`) does three things for this wrapper:

1. Adds this directory to the include path so `@cInclude` can find
   `tinyobj_wrapper.h`:

   ```zig
   exe.root_module.addIncludePath(b.path("src/wrapper/tinyobj"));
   ```

2. Compiles the `.cpp` as part of the executable, with `link_libc` +
   `link_libcpp` enabled everywhere:

   ```zig
   exe.root_module.addCSourceFile(.{
       .file = b.path("src/wrapper/tinyobj/tinyobj_wrapper.cpp"),
       .flags = &.{ "-std=c++17", "-fno-exceptions" },
   });
   ```

3. Links the system-provided tinyobjloader static archive via
   pkg-config:

   ```zig
   exe.root_module.linkSystemLibrary("tinyobjloader", .{});
   ```

The Zig side ([`src/c.zig`](../../c.zig)) then pulls the C-ABI
prototypes in alongside the GLFW and Vulkan headers:

```zig
pub const c = @cImport({
    @cDefine("GLFW_INCLUDE_VULKAN", {});
    @cInclude("GLFW/glfw3.h");
    @cInclude("vulkan/vulkan_beta.h");
    @cInclude("tinyobj_wrapper.h");
});
```

and [`Model.zig`](../../Model.zig)'s `Builder.loadModel` calls
`c.tinyobj_load_bytes(...)`, frees the returned arrays with
`c.tinyobj_free(...)`, and copies vertices/indices into the Zig
`Builder`'s `ArrayList`s.

## Alternatives that were considered

- **Use a pure-C OBJ loader instead** — e.g.
  [`tinyobjloader-c`](https://github.com/syoyo/tinyobjloader-c) is a
  separate project. Then `@cImport("tinyobj_loader_c.h")` would work
  directly. The upstream Little Vulkan Engine tutorial uses the C++
  one, so we kept parity with it.
- **Write the parser in Zig** — what the first version of this
  feature did. No FFI, no C++, but the parser has to be maintained
  in-tree.
- **Header-only inline approach** — define
  `TINYOBJLOADER_IMPLEMENTATION` and `#include "tiny_obj_loader.h"`
  in our `.cpp`, skipping the static library. Still needs this
  wrapper for the same C↔C++ reason — it only saves the link step.

So the wrapper isn't bureaucracy; it's the **C↔C++ translation
layer** that lets `@cImport` see something it can actually parse, and
lets the Zig side avoid linking against and reasoning about a C++
standard library.
