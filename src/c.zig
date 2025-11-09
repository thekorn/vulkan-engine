pub const c = @cImport({
    // See https://github.com/ziglang/zig/issues/515
    @cDefine("GLFW_INCLUDE_VULKAN", {});
    @cInclude("GLFW/glfw3.h");
});
