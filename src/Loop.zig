const Window = @import("Window.zig");

const Self = @This();
window: *Window,

pub fn init(window: *Window) !Self {
    return .{ .window = window };
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn is_running(self: *Self) bool {
    return !self.window.should_close();
}
