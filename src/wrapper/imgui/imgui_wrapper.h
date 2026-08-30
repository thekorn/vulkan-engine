// Tiny C-ABI shim over a few Dear ImGui / cimgui APIs that can't be
// consumed directly from Zig.
//
// `cimgui` already exposes the full Dear ImGui surface as C functions,
// but the auto-generated `struct ImGuiIO` declaration contains
// `[*c]ImGuiContext` fields where `ImGuiContext` is only
// forward-declared (and therefore opaque in Zig's translated C module). That
// makes it impossible to dereference the `[*c]ImGuiIO` returned by
// `igGetIO_Nil()` from Zig (the language correctly rejects an
// "indexable pointer to opaque type"). This wrapper does the IO struct
// access on the C++ side and exposes small C helpers for the engine.

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

/// Disable the default Dear ImGui `imgui.ini` persistence file. Safe to
/// call before any context exists — no-ops in that case.
void imgui_disable_ini_file(void);

#ifdef __cplusplus
}
#endif

#endif // IMGUI_WRAPPER_H
