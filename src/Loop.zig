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

test "resetShutdownForTesting clears the shutdown flag" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    shutdown_requested.store(true, .release);
    resetShutdownForTesting();

    try std.testing.expect(!shutdown_requested.load(.acquire));
}

test "Loop has expected fields and types" {
    const info = @typeInfo(Self).@"struct";
    try std.testing.expectEqual(@as(usize, 1), info.fields.len);
    try std.testing.expectEqual(*Window, @FieldType(Self, "window"));
}

test "is_running returns false once shutdown is requested, regardless of window" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    resetShutdownForTesting();
    defer resetShutdownForTesting();

    // Window is never dereferenced when shutdown is requested, because
    // the atomic check short-circuits before touching `self.window`.
    var window: Window = undefined;
    var loop: Self = .{ .window = &window };

    shutdown_requested.store(true, .release);
    try std.testing.expect(!loop.is_running());
}

test "handleSignal is idempotent (multiple deliveries leave flag true)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    resetShutdownForTesting();
    defer resetShutdownForTesting();

    handleSignal(posix.SIG.INT);
    handleSignal(posix.SIG.TERM);
    handleSignal(posix.SIG.HUP);

    try std.testing.expect(shutdown_requested.load(.acquire));
}
