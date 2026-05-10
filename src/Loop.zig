const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const Window = @import("Window.zig");

const Self = @This();
window: *Window,

/// Set to true by a signal handler when the user requests termination
/// (e.g. SIGINT via Ctrl+C, SIGTERM, or SIGHUP). Checked every iteration
/// of the main loop so the app can shut down cleanly and run all
/// `defer`/`deinit` paths.
var shutdown_requested: std.atomic.Value(bool) = .init(false);

fn handleSignal(_: posix.SIG) callconv(.c) void {
    shutdown_requested.store(true, .release);
}

fn installSignalHandlers() !void {
    if (builtin.os.tag == .windows) return;

    var act: posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.HUP, &act, null);
}

pub fn init(window: *Window) !Self {
    try installSignalHandlers();
    return .{ .window = window };
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn is_running(self: *Self) bool {
    if (shutdown_requested.load(.acquire)) return false;
    return !self.window.should_close();
}

/// Test-only helper to reset the global shutdown flag between tests.
fn resetShutdownForTesting() void {
    shutdown_requested.store(false, .release);
}

test "shutdown signal stops the loop" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    resetShutdownForTesting();
    defer resetShutdownForTesting();

    // Simulate a delivered signal without actually raising one, to keep
    // the test deterministic and independent of the test runner's own
    // signal handling.
    handleSignal(posix.SIG.INT);

    try std.testing.expect(shutdown_requested.load(.acquire));
}
