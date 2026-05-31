// Tiny C-ABI shim over a few Dear ImGui / cimgui APIs that can't be
// consumed directly from Zig.
//
// `cimgui` already exposes the full Dear ImGui surface as C functions,
// but the auto-generated `struct ImGuiIO` declaration contains
// `[*c]ImGuiContext` fields where `ImGuiContext` is only
// forward-declared (and therefore opaque in the Zig `@cImport`). That
// makes it impossible to dereference the `[*c]ImGuiIO` returned by
// `igGetIO_Nil()` from Zig (the language correctly rejects an
// "indexable pointer to opaque type"). This wrapper does the IO struct
// access on the C++ side and returns just the bool the engine actually
// needs.

#ifndef IMGUI_WRAPPER_H
#define IMGUI_WRAPPER_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Returns whether Dear ImGui currently wants to capture the mouse
/// (i.e. the cursor is over an ImGui window or a widget has the active
/// mouse drag). Mirrors `ImGui::GetIO().WantCaptureMouse`. Safe to call
/// before any context exists — returns `false` in that case.
bool imgui_want_capture_mouse(void);

#ifdef __cplusplus
}
#endif

#endif // IMGUI_WRAPPER_H
