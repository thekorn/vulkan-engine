pub const c = @cImport({
    // See https://github.com/ziglang/zig/issues/515
    @cDefine("GLFW_INCLUDE_VULKAN", {});
    @cInclude("GLFW/glfw3.h");
    @cInclude("vulkan/vulkan_beta.h");
});

// Separate @cImport so cglm preprocessor tweaks never reach glfw/vulkan.
// Undefs apply only here; the real toolchain still exposes NEON/SSE/AVX.
pub const cglm = @cImport({
    // translate-c does not handle Clang's `__attribute(...)` keyword; map
    // it to the usual `__attribute__(x)` macro spelling.
    @cDefine("__attribute(x)", "__attribute__(x)");

    // Strip compiler SIMD feature flags so cglm picks scalar code. translate-c
    // cannot parse vendor intrinsic headers; cglm vec/mat types stay plain
    // float arrays, so layout matches a normal C build. Scoped to this import.
    // (Project uses vec2 only; those helpers are scalar in cglm anyway.)

    // ARM (Apple Silicon, Linux arm64, MSVC ARM64)
    @cUndef("__ARM_NEON");
    @cUndef("__ARM_NEON__");
    @cUndef("__ARM_NEON_FP");
    @cUndef("_M_ARM64");
    @cUndef("_M_ARM64EC");
    @cUndef("CGLM_NEON_FP");

    // x86 SIMD detection (native x86_64 builds).
    @cUndef("__SSE__");
    @cUndef("__SSE2__");
    @cUndef("__SSE3__");
    @cUndef("__SSSE3__");
    @cUndef("__SSE4__");
    @cUndef("__SSE4_1__");
    @cUndef("__SSE4_2__");
    @cUndef("__AVX__");
    @cUndef("__AVX2__");
    @cUndef("__FMA__");
    @cUndef("__FMA4__");

    @cInclude("cglm/cglm.h");
    //@cInclude("cglm/struct.h");
});
