const std = @import("std");
const builtin = @import("builtin");

const c = @import("c.zig").c;
const Vulkan = @import("Vulkan.zig");
const Window = @import("Window.zig");

const Self = @This();
window: Window,
enable_validation_layers: bool,

pub fn init(alloc: std.mem.Allocator, window: Window) !Self {
    const enable_validation_layers = builtin.mode == .Debug;

    var instance = try Vulkan.init(alloc, enable_validation_layers);
    defer instance.deinit();

    return .{
        .window = window,
        .enable_validation_layers = enable_validation_layers,
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
}
