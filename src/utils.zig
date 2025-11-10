const c = @import("c.zig").c;

pub fn checkSuccess(result: c.VkResult) !void {
    switch (result) {
        c.VK_SUCCESS => {},
        else => return error.Unexpected,
    }
}
