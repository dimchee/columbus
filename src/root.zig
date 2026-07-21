const std = @import("std");
const Io = std.Io;
pub const way = @import("wayland.zig");

pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

test "basic add functionality" {
    try std.testing.expect(3 + 7 == 10);
}
