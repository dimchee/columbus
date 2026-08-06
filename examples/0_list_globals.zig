const std = @import("std");
const clb = @import("columbus");
const way = clb.way;
const meta = clb.meta;
const Str = way.types.str;


pub fn main(init: std.process.Init) !void {
    var env = clb.Env.init();
    const display = env.new(way.wayland.wl_display);
    const registry = env.new(way.wayland.wl_registry);
    const wl_callback = env.new(way.wayland.wl_callback);
    var con = try clb.Connection.initDefault(init);
    con.io.sender.push(display, way.wayland.wl_display.Request.get_registry{ .registry = registry });
    con.io.sender.push(display, way.wayland.wl_display.Request.sync{ .callback = wl_callback });
    con.send();
    try std.Io.sleep(init.io, .fromMilliseconds(50), .real); // too fast otherwise
    for (1..40) |_| {
        con.recv();
        while (con.io.recver.popHeader(&env.env)) |t_id| switch (t_id.val) {
            meta.index(.event, way.wayland.wl_registry.Event.global).?.val => {
                const x = con.io.recver.popOp(way.wayland.wl_registry.Event.global);
                std.debug.print("global name: {} version: {} interface: {f}\n", .{ x.name, x.version, x.interface });
            },
            meta.lists.events.types.len...std.math.maxInt(usize) => unreachable,
            inline else => |i| {
                _ = con.io.recver.popOp(meta.lists.events.types[i]);
                std.debug.print("Ignored Msg {s}\n", .{@typeName(meta.lists.events.types[i])});
            },
        };
    }
}
