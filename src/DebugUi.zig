//! Dear ImGui debug-UI integration.
//!
//! Owns the global `ImGuiContext`, the GLFW + Vulkan backends and a
//! dedicated descriptor pool that the Vulkan backend allocates its
//! per-texture descriptor sets out of (the engine's `FirstApp.globalPool`
//! only holds `VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER` slots, which is the
//! wrong type for the ImGui font / user textures).
//!
//! Mirrors the layout of the engine's other thin wrappers: a single
//! `init` / `deinit` pair plus a `beginFrame` / `render` pair the main
//! loop calls each frame. The actual UI building (`igBegin`, `igText`,
//! `igEnd`, …) happens in `FirstApp.run` between `beginFrame` and
//! `render` so render-system independence stays the same as for
//! `SimpleRenderSystem` / `PointLightSystem`.

const std = @import("std");

const c = @import("c.zig").c;
const Device = @import("Device.zig");
const Vulkan = @import("Vulkan.zig");
const Window = @import("Window.zig");
const checkSuccess = @import("utils.zig").checkSuccess;

const Self = @This();

/// Size of the dedicated descriptor pool that the ImGui Vulkan
/// backend allocates its per-texture descriptor sets from. The font
/// atlas counts as one texture; the rest of the headroom is for any
/// user textures the debug UI registers via
/// `ImGui_ImplVulkan_AddTexture` (currently none, but ImGui happily
/// allocates a few up-front).
const descriptor_pool_size: u32 = 64;

device: *Device,
descriptorPool: c.VkDescriptorPool,
context: ?*c.ImGuiContext,

pub fn init(
    alloc: std.mem.Allocator,
    device: *Device,
    window: *Window,
    renderPass: c.VkRenderPass,
    imageCount: u32,
) !Self {
    // Dedicated descriptor pool sized for the
    // `VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER` allocations the
    // ImGui Vulkan backend issues. The backend can also create its
    // own pool if we pass `DescriptorPool = null` and
    // `DescriptorPoolSize > 0`, but owning it here keeps the
    // destruction order obvious (we tear down the pool in `deinit`
    // after `ImGui_ImplVulkan_Shutdown`).
    // Recent versions of `imgui_impl_vulkan.cpp` allocate descriptor
    // sets of several different types (separate samplers + sampled
    // images for the font atlas and any user-registered textures, plus
    // a combined image sampler entry for back-compat). Mirror the
    // pool sizes recommended by the upstream `MINIMUM_SAMPLER_POOL`
    // / `MINIMUM_SAMPLED_IMAGE_POOL` constants exposed in
    // `cimgui_impl.h` so we don't hit
    // `VK_ERROR_OUT_OF_POOL_MEMORY` (or, on drivers that don't surface
    // that error, a stream of validation-layer warnings).
    const poolSizes = [_]c.VkDescriptorPoolSize{
        .{
            .type = c.VK_DESCRIPTOR_TYPE_SAMPLER,
            .descriptorCount = descriptor_pool_size,
        },
        .{
            .type = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
            .descriptorCount = descriptor_pool_size,
        },
        .{
            .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = descriptor_pool_size,
        },
    };
    const poolInfo: c.VkDescriptorPoolCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .flags = c.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
        .maxSets = descriptor_pool_size,
        .poolSizeCount = poolSizes.len,
        .pPoolSizes = &poolSizes,
    };
    // SAFETY: filled in by vkCreateDescriptorPool below before any read.
    var descriptorPool: c.VkDescriptorPool = undefined;
    try checkSuccess(c.vkCreateDescriptorPool(
        device.globalDevice,
        &poolInfo,
        null,
        &descriptorPool,
    ));
    errdefer c.vkDestroyDescriptorPool(device.globalDevice, descriptorPool, null);

    const context = c.igCreateContext(null) orelse return error.ImGuiCreateContextFailed;
    errdefer c.igDestroyContext(context);
    c.igStyleColorsDark(null);

    // GLFW backend. `install_callbacks = true` chains the ImGui
    // keyboard/mouse callbacks on top of any previously-installed
    // GLFW callbacks; the engine `Window` only sets the framebuffer
    // resize callback, which ImGui does *not* override, so the
    // existing resize-handling path keeps working untouched.
    if (!c.ImGui_ImplGlfw_InitForVulkan(window.instance, true)) {
        return error.ImGuiGlfwInitFailed;
    }
    errdefer c.ImGui_ImplGlfw_Shutdown();

    // Vulkan backend. The queue family index isn't cached on `Device`,
    // so re-query it here (the surface is owned by `Device`).
    const indices = try Vulkan.findQueueFamilies(alloc, device.physicalDevice, device.surface);

    var initInfo: c.ImGui_ImplVulkan_InitInfo = std.mem.zeroes(c.ImGui_ImplVulkan_InitInfo);
    initInfo.ApiVersion = c.VK_API_VERSION_1_0;
    initInfo.Instance = device.vulkanInstance.instance;
    initInfo.PhysicalDevice = device.physicalDevice;
    initInfo.Device = device.globalDevice;
    initInfo.QueueFamily = indices.graphicsFamily.?;
    initInfo.Queue = device.graphicsQueue;
    initInfo.DescriptorPool = descriptorPool;
    initInfo.MinImageCount = imageCount;
    initInfo.ImageCount = imageCount;
    initInfo.PipelineInfoMain.RenderPass = renderPass;
    initInfo.PipelineInfoMain.Subpass = 0;
    initInfo.PipelineInfoMain.MSAASamples = c.VK_SAMPLE_COUNT_1_BIT;

    if (!c.ImGui_ImplVulkan_Init(&initInfo)) {
        return error.ImGuiVulkanInitFailed;
    }

    return .{
        .device = device,
        .descriptorPool = descriptorPool,
        .context = context,
    };
}

pub fn deinit(self: *Self) void {
    // The GPU may still be using the ImGui pipelines / descriptor sets
    // when we tear them down; wait for it to become idle so the
    // validation layers don't complain.
    _ = c.vkDeviceWaitIdle(self.device.globalDevice);
    c.ImGui_ImplVulkan_Shutdown();
    c.ImGui_ImplGlfw_Shutdown();
    c.igDestroyContext(self.context);
    c.vkDestroyDescriptorPool(self.device.globalDevice, self.descriptorPool, null);
}

/// Start a new ImGui frame. Must be called once per main-loop tick,
/// *before* any `igBegin` / `igText` / `igEnd` calls. The matching
/// `render` call submits the resulting draw data.
pub fn beginFrame(_: *Self) void {
    c.ImGui_ImplVulkan_NewFrame();
    c.ImGui_ImplGlfw_NewFrame();
    c.igNewFrame();
}

/// Finalize the current ImGui frame and record its draw commands into
/// `commandBuffer`. Must be called inside an active render pass that
/// targets the swapchain image (i.e. between
/// `Renderer.beginSwapChainRenderPass` and
/// `Renderer.endSwapChainRenderPass`).
pub fn render(_: *Self, commandBuffer: c.VkCommandBuffer) void {
    c.igRender();
    c.ImGui_ImplVulkan_RenderDrawData(c.igGetDrawData(), commandBuffer, null);
}

/// Convenience wrapper for `igTextUnformatted` that lets callers use
/// Zig-style formatting. The formatted string is written into the
/// caller-supplied stack buffer; on overflow the line is truncated
/// silently (the buffer is sized for typical debug lines, ~256 bytes).
pub fn text(_: *Self, buf: []u8, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrintZ(buf, fmt, args) catch blk: {
        // Truncated: reserve room for the NUL terminator and emit
        // whatever did fit.
        if (buf.len == 0) return;
        buf[buf.len - 1] = 0;
        break :blk buf[0 .. buf.len - 1 :0];
    };
    // Passing `null` for `text_end` tells ImGui to scan for the NUL
    // terminator, which `bufPrintZ` guarantees is present.
    c.igTextUnformatted(s.ptr, null);
}
