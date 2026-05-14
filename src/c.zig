pub const c = @cImport({
    // See https://github.com/ziglang/zig/issues/515
    @cDefine("GLFW_INCLUDE_VULKAN", {});
    @cInclude("GLFW/glfw3.h");
    @cInclude("vulkan/vulkan_beta.h");
});

// cglm lives in its own translation unit because the wrapper redefines
// the `__attribute` macro, which we don't want to leak into glfw/vulkan
// headers.
pub const cglm = @cImport({
    @cInclude("cglm_wrapper.h");
});
