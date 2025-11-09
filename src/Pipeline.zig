const std = @import("std");
const c = @import("c.zig").c;

const Self = @This();

pub fn init(fragShader: []const u8, vertShader: []const u8) !Self {
    std.log.info("frag shader len: {d}", .{fragShader.len});
    std.log.info("vert shader len: {d}", .{vertShader.len});
    return .{};
}
