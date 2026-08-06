const std = @import("std");
const Io = std.Io;
pub const way = @import("wayland.zig");
pub const meta = @import("meta.zig");
pub const rb = @import("ringbuffer.zig");
pub const Connection = @import("connection.zig");

// TODO Something like:
// Env.register(struct {
//     // Must be marked pub
//     pub fn print_global(x: way.wayland.wl_registry.Event.global) void {
//         std.debug.print("global name: {} version: {} interface: {s}\n", .{ x.name, x.version, x.interface });
//     }
// });
//

pub const Env = struct {
    env: [64]meta.Index(.interface), // Maps id to TypeId
    id: u32,
    pub fn init() @This() {
        return .{ .id = 0, .env = undefined };
    }
    pub fn new(self: *@This(), X: type) X {
        self.id += 1;
        self.env[self.id] = comptime meta.index(.interface, X).?;
        return .{ .id = self.id };
    }
};
