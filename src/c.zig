pub const c = @cImport({
    // See https://github.com/ziglang/zig/issues/515
    @cDefine("GLFW_INCLUDE_VULKAN", {});
    @cInclude("GLFW/glfw3.h");
    @cInclude("vulkan/vulkan_beta.h");
    @cInclude("tinyobj_wrapper.h");

    // Dear ImGui (via cimgui). `CIMGUI_DEFINE_ENUMS_AND_STRUCTS` tells
    // `cimgui.h` / `cimgui_impl.h` to emit C struct + enum definitions
    // (otherwise they only forward-declare them, which is fine for C++
    // but useless for Zig). `CIMGUI_USE_GLFW` / `CIMGUI_USE_VULKAN`
    // gate the backend declarations in `cimgui_impl.h` and must match
    // the same defines passed to the C++ compiler in `build.zig`.
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", {});
    @cDefine("CIMGUI_USE_GLFW", {});
    @cDefine("CIMGUI_USE_VULKAN", {});
    @cInclude("cimgui.h");
    @cInclude("cimgui_impl.h");

    // Tiny in-tree C-ABI shim that bridges the few Dear ImGui calls
    // the cimport above can't materialize cleanly (see
    // `src/wrapper/imgui/imgui_wrapper.h`).
    @cInclude("imgui_wrapper.h");
});
