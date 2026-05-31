# `imgui_wrapper` — why this directory exists

A tiny **C-ABI shim** over a few Dear ImGui / cimgui APIs that the
Zig `@cImport` can't materialize cleanly. Right now it just exposes
`ImGui::GetIO().WantCaptureMouse` as `imgui_want_capture_mouse()` so
the engine's input controller can ignore the mouse while ImGui is
using it.

## Why we can't just call `igGetIO_Nil()` from Zig directly

`cimgui` already exposes the entire Dear ImGui surface as plain C
functions — `igGetIO_Nil` returns `[*c]ImGuiIO`, and `ImGuiIO` is a
real `extern struct` in the cimport.

The catch: `ImGuiIO` contains a `Ctx: [*c]ImGuiContext` field, and
`ImGuiContext` is only **forward-declared** in the cimgui public
header.
The Zig translator therefore demotes it to an `opaque` type (the
exact warning the compiler emits is *"struct demoted to opaque type
— has opaque field"*). A pointer-to-opaque is fine by itself, but a
`[*c]opaque` is an "indexable pointer to opaque type", which Zig
correctly refuses — there's no way to do pointer arithmetic on a
type whose size isn't known.

Concretely:

```zig
const io = c.igGetIO_Nil();      // [*c]ImGuiIO
return io.*.WantCaptureMouse;    // error: indexable pointer to opaque type
//        ^^ triggers materializing ImGuiIO, which fails because of `Ctx`.
```

There's no `igWantCaptureMouse()` C helper in cimgui to sidestep
this, so we add one ourselves.

## What the shim does

`imgui_wrapper.cpp` is a single-translation-unit C++ file that
includes `cimgui.h` (where the IO struct is fully defined for C++
consumers) and exposes a plain `bool imgui_want_capture_mouse(void)`
function:

```cpp
extern "C" bool imgui_want_capture_mouse(void) {
    ImGuiIO *io = igGetIO_Nil();
    if (io == nullptr) return false;
    return io->WantCaptureMouse;
}
```

The matching header (`imgui_wrapper.h`) is pure C and gets pulled
into Zig via `@cInclude("imgui_wrapper.h")` in
[`src/c.zig`](../../c.zig).

## Wiring it up

`build.zig` does two things:

1. Adds this directory to the include path so `@cInclude` finds
   the header:

   ```zig
   exe.root_module.addIncludePath(b.path("src/wrapper/imgui"));
   ```

2. Compiles the `.cpp` against the cimgui include tree (assembled
   just above by `addWriteFiles`), with the same `CIMGUI_USE_*`
   defines the rest of the Dear ImGui sources use:

   ```zig
   exe.root_module.addCSourceFile(.{
       .file = b.path("src/wrapper/imgui/imgui_wrapper.cpp"),
       .flags = &.{
           "-std=c++17", "-fno-exceptions", "-fno-rtti",
           "-DCIMGUI_USE_GLFW", "-DCIMGUI_USE_VULKAN",
       },
   });
   ```

## Why not redefine `ImGuiIO` in Zig

`ImGuiIO` has ~80 fields with several pointers to other opaque
types. Reproducing the exact std-layout in Zig would be brittle and
break silently whenever Dear ImGui adds a field. A C++ shim is the
upstream-supported way to access IO state from outside the C++
world, mirroring why [`../tinyobj/`](../tinyobj/README.md) exists.
