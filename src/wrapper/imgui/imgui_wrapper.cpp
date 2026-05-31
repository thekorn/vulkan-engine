// C-ABI shim over a few Dear ImGui APIs that can't be consumed
// directly from the Zig `@cImport` (see `imgui_wrapper.h` for the
// rationale).

#define CIMGUI_DEFINE_ENUMS_AND_STRUCTS
#include "cimgui.h"

#include "imgui_wrapper.h"

extern "C" bool imgui_want_capture_mouse(void) {
    // `igGetIO_Nil()` returns NULL when no ImGui context has been
    // created yet; treat that as "ImGui doesn't want the mouse" so
    // callers can poll this safely from startup paths too.
    ImGuiIO *io = igGetIO_Nil();
    if (io == nullptr) return false;
    return io->WantCaptureMouse;
}
