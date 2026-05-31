// C-ABI shim over a few Dear ImGui APIs that can't be consumed
// directly from the Zig `@cImport` (see `imgui_wrapper.h` for the
// rationale).

#define CIMGUI_DEFINE_ENUMS_AND_STRUCTS
#include "cimgui.h"

#include "imgui_wrapper.h"

extern "C" bool imgui_want_capture_mouse(void) {
    // `igGetIO_Nil()` is the cimgui wrapper for `ImGui::GetIO()`, which
    // asserts on a missing current context rather than returning NULL —
    // calling it before `igCreateContext` would abort. Gate on
    // `igGetCurrentContext()` (which *does* return NULL when no context
    // exists) so this helper can be polled safely from startup paths
    // too.
    if (igGetCurrentContext() == nullptr) return false;
    return igGetIO_Nil()->WantCaptureMouse;
}
