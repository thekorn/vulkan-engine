//! Minimal application root that shows *only* the custom
//! immediate-mode UI (`UiRenderSystem`) plus the Dear ImGui debug
//! overlay — no 3D scene, camera, lighting or textures.
//!
//! Mirrors the lifetime/ownership conventions of `TutorialApp` (window
//! and device are heap-allocated so sub-components can hold stable
//! back-pointers) but drops everything the 3D pipeline needs: there
//! is no global UBO, no descriptor pool and no `GameObject` map. The
//! main loop just queues a few colored squares each frame and draws
//! them under the debug overlay.

const std = @import("std");

const c = @import("c.zig").c;
const DebugUi = @import("DebugUi.zig");
const Device = @import("Device.zig");
const Loop = @import("Loop.zig");
const Renderer = @import("Renderer.zig");
const UiRenderSystem = @import("systems/UiRenderSystem.zig");
const Window = @import("Window.zig");

const Self = @This();

pub const width = 800;
pub const height = 600;

alloc: std.mem.Allocator,
// `window` and `device` are heap-allocated and own their own lifetime;
// holding them as stable pointers keeps the back-pointers stored in
// sub-components (Device, Loop, Renderer) valid when `Self` is copied
// by value out of `init`.
window: *Window,
device: *Device,
loop: Loop,
renderer: Renderer,

pub fn init(alloc: std.mem.Allocator) !Self {
    const window = try Window.init(alloc, width, height);
    errdefer window.deinit();

    const device = try Device.init(alloc, window);
    errdefer device.deinit();

    var loop = try Loop.init(window);
    errdefer loop.deinit();

    var renderer = try Renderer.init(alloc, window, device);
    errdefer renderer.deinit();

    return .{
        .alloc = alloc,
        .window = window,
        .device = device,
        .loop = loop,
        .renderer = renderer,
    };
}

pub fn deinit(self: *Self) void {
    std.log.scoped(.secondApp).info("deinit second app", .{});
    self.renderer.deinit();
    self.loop.deinit();
    self.device.deinit();
    self.window.deinit();
}

pub fn run(self: *Self) !void {
    // Custom immediate-mode UI overlay. Binds no vertex buffers (the
    // quad is generated in the vertex shader); each frame the main
    // loop resets it with `beginFrame`, queues rectangles, and records
    // the draws via `render`.
    var uiRenderSystem = try UiRenderSystem.init(
        self.alloc,
        self.device,
        self.renderer.getSwapChainRenderPass(),
    );
    defer uiRenderSystem.deinit();

    // Dear ImGui debug overlay, built against the same swapchain
    // render pass so its draws slot into the existing render-pass
    // scope after the UI squares.
    var debugUi = try DebugUi.init(
        self.alloc,
        self.device,
        self.window,
        self.renderer.getSwapChainRenderPass(),
        @intCast(self.renderer.swapChain.?.swapChainImages.len),
    );
    defer debugUi.deinit();

    // Monotonic GLFW clock (seconds since `glfwInit`) for per-frame
    // delta time.
    var currentTime: f64 = c.glfwGetTime();

    // Scratch buffer reused across frames for `DebugUi.text` lines.
    var debugText: [256]u8 = undefined;

    while (self.loop.is_running()) {
        c.glfwPollEvents();

        const newTime: f64 = c.glfwGetTime();
        const frameTime: f32 = @floatCast(newTime - currentTime);
        currentTime = newTime;

        // Build this frame's ImGui draw data *before* recording any
        // Vulkan commands; `debugUi.render(cb)` below replays it into
        // the swapchain render pass.
        debugUi.beginFrame();
        {
            _ = c.igBegin("Debug", null, 0);
            debugUi.text(&debugText, "frame time: {d:.2} ms", .{frameTime * 1000.0});
            debugUi.text(&debugText, "fps: {d:.1}", .{1.0 / frameTime});
            c.igEnd();
        }

        const beginResult = self.renderer.beginFrame() catch |err| switch (err) {
            // The swapchain was recreated with a different format, so
            // the UI pipeline / ImGui backend (built against the old
            // render pass) are invalid. Rebuild both and skip the
            // frame.
            error.SwapChainFormatChanged => {
                uiRenderSystem.deinit();
                uiRenderSystem = try UiRenderSystem.init(
                    self.alloc,
                    self.device,
                    self.renderer.getSwapChainRenderPass(),
                );
                try debugUi.recreate(self.renderer.getSwapChainRenderPass());
                continue;
            },
            else => return err,
        };

        if (beginResult) |commandBuffer| {
            // Current cursor position in framebuffer-pixel space (the
            // same space the UI rects live in). GLFW reports the cursor
            // in logical window coordinates, so scale it by the
            // framebuffer/window ratio (≠ 1 on HiDPI/retina displays).
            const mouse = self.getCursorInFramebufferSpace();

            // Build this frame's immediate-mode UI: four colored
            // squares in a row, each `square` px wide with a `gap` px
            // gap, starting `margin` px from the top-left corner. When
            // the cursor hovers a square it brightens to a lighter
            // tint.
            uiRenderSystem.beginFrame();
            {
                const square: f32 = 80.0;
                const gap: f32 = 20.0;
                const margin: f32 = 50.0;
                const colors = [_][4]f32{
                    .{ 0.90, 0.20, 0.20, 1.0 }, // red
                    .{ 0.20, 0.80, 0.30, 1.0 }, // green
                    .{ 0.20, 0.45, 0.90, 1.0 }, // blue
                    .{ 0.95, 0.80, 0.20, 1.0 }, // yellow
                };
                const hoverColors = [_][4]f32{
                    .{ 1.00, 0.55, 0.55, 1.0 }, // light red
                    .{ 0.55, 1.00, 0.65, 1.0 }, // light green
                    .{ 0.55, 0.75, 1.00, 1.0 }, // light blue
                    .{ 1.00, 0.95, 0.55, 1.0 }, // light yellow
                };
                for (colors, hoverColors, 0..) |col, hoverCol, i| {
                    const x = margin + @as(f32, @floatFromInt(i)) * (square + gap);
                    const hovered = mouse.x >= x and mouse.x < x + square and
                        mouse.y >= margin and mouse.y < margin + square;
                    uiRenderSystem.rect(x, margin, square, square, if (hovered) hoverCol else col);
                }
            }

            // render
            self.renderer.beginSwapChainRenderPass(commandBuffer);
            uiRenderSystem.render(
                commandBuffer,
                self.renderer.swapChain.?.swapChainExtent,
            );
            // ImGui must be the *last* thing recorded inside the
            // swapchain render pass so its draw commands composite on
            // top of the UI squares.
            debugUi.render(commandBuffer);
            self.renderer.endSwapChainRenderPass(commandBuffer);
            self.renderer.endFrame() catch |err| switch (err) {
                error.SwapChainFormatChanged => {
                    uiRenderSystem.deinit();
                    uiRenderSystem = try UiRenderSystem.init(
                        self.alloc,
                        self.device,
                        self.renderer.getSwapChainRenderPass(),
                    );
                    try debugUi.recreate(self.renderer.getSwapChainRenderPass());
                    continue;
                },
                else => return err,
            };
        }
    }

    // Wait for the GPU to finish before any resources are torn down.
    _ = c.vkDeviceWaitIdle(self.device.globalDevice);
}

/// Current cursor position converted into framebuffer-pixel space —
/// the same coordinate system the UI rects use. GLFW reports the
/// cursor in logical window coordinates; on HiDPI / retina displays
/// the framebuffer is larger than the window, so scale by the
/// framebuffer/window ratio. Returns `(0, 0)` when the window size is
/// degenerate.
fn getCursorInFramebufferSpace(self: *Self) struct { x: f32, y: f32 } {
    var cx: f64 = 0;
    var cy: f64 = 0;
    c.glfwGetCursorPos(self.window.instance, &cx, &cy);

    var winW: c_int = 0;
    var winH: c_int = 0;
    c.glfwGetWindowSize(self.window.instance, &winW, &winH);

    var fbW: c_int = 0;
    var fbH: c_int = 0;
    c.glfwGetFramebufferSize(self.window.instance, &fbW, &fbH);

    if (winW <= 0 or winH <= 0) return .{ .x = 0, .y = 0 };

    const scaleX = @as(f32, @floatFromInt(fbW)) / @as(f32, @floatFromInt(winW));
    const scaleY = @as(f32, @floatFromInt(fbH)) / @as(f32, @floatFromInt(winH));

    return .{
        .x = @as(f32, @floatCast(cx)) * scaleX,
        .y = @as(f32, @floatCast(cy)) * scaleY,
    };
}

test "CustomUiApp default window dimensions are 800x600" {
    try std.testing.expectEqual(@as(comptime_int, 800), width);
    try std.testing.expectEqual(@as(comptime_int, 600), height);
}

test "CustomUiApp has expected fields and types" {
    const fields = @typeInfo(Self).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 5), fields.len);
    try std.testing.expectEqual(std.mem.Allocator, @FieldType(Self, "alloc"));
    try std.testing.expectEqual(*Window, @FieldType(Self, "window"));
    try std.testing.expectEqual(*Device, @FieldType(Self, "device"));
    try std.testing.expectEqual(Loop, @FieldType(Self, "loop"));
    try std.testing.expectEqual(Renderer, @FieldType(Self, "renderer"));
}
