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
    @cDefine("__attribute(x)", "__attribute__(x)");
    @cUndef("__ARM_NEON");

    @cUndef("__ARM_NEON__");
    @cUndef("__ARM_NEON_FP");
    @cUndef("_M_ARM64");
    @cUndef("_M_ARM64EC");
    @cUndef("CGLM_NEON_FP");

    @cUndef("__SSE__");
    @cUndef("__SSE2__");
    @cUndef("__AVX__");

    @cInclude("cglm/cglm.h");
});
