# `imgui_wrapper` — why this directory exists

A tiny **C-ABI shim** over a few Dear ImGui / cimgui APIs that the
Zig C translator can't materialize cleanly. Right now it exposes
`ImGui::GetIO().WantCaptureMouse` as `imgui_want_capture_mouse()` so
the engine's input controller can ignore the mouse while ImGui is
using it, and `imgui_disable_ini_file()` so the debug UI does not
write the default Dear ImGui `imgui.ini` state file next to the binary.

## Why we can't just call `igGetIO_Nil()` from Zig directly

`cimgui` already exposes the entire Dear ImGui surface as plain C
functions — `igGetIO_Nil` returns `[*c]ImGuiIO`, and `ImGuiIO` is a
real `extern struct` in the translated module.

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
this. The Dear ImGui `IniFilename` setting also lives on `ImGuiIO`, so
disabling the automatic `imgui.ini` file needs the same bridge.

## What the shim does

`imgui_wrapper.cpp` is a single-translation-unit C++ file that
includes `cimgui.h` (where the IO struct is fully defined for C++
consumers) and exposes plain C helpers:

```cpp
extern "C" bool imgui_want_capture_mouse(void) {
    if (igGetCurrentContext() == nullptr) return false;
    return igGetIO_Nil()->WantCaptureMouse;
}

extern "C" void imgui_disable_ini_file(void) {
    if (igGetCurrentContext() == nullptr) return;
    igGetIO_Nil()->IniFilename = nullptr;
}
```

The matching header (`imgui_wrapper.h`) is pure C and is included by
the umbrella header passed to `addTranslateC` in `build.zig`.
[`src/c.zig`](../../c.zig) re-exports the generated module.

## Wiring it up

`build.zig` does two things:

1. Adds this directory to the translation include path so it finds
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
           "-fno-sanitize-coverage=trace-cmp,inline-8bit-counters,pc-table",
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
