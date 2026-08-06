const std = @import("std");
const clb = @import("columbus");
const way = clb.way;
const meta = clb.meta;
const Str = way.types.str;

pub fn main(init: std.process.Init) !void {
    var env = clb.Env.init();
    const display = env.new(way.protocol.wayland.wl_display);
    const registry = env.new(way.protocol.wayland.wl_registry);
    const wl_callback = env.new(way.protocol.wayland.wl_callback);
    var con = try clb.Connection.initDefault(init);
    con.io.sender.push(display, way.protocol.wayland.wl_display.Request.get_registry{ .registry = registry });
    con.io.sender.push(display, way.protocol.wayland.wl_display.Request.sync{ .callback = wl_callback });
    con.send();

    const wl_compositor = env.new(way.protocol.wayland.wl_compositor);
    const wl_shm = env.new(way.protocol.wayland.wl_shm);
    const xdg_wm_base = env.new(way.protocol.xdg_shell.xdg_wm_base);
    try std.Io.sleep(init.io, .fromMilliseconds(50), .real); // too fast otherwise
    for (1..40) |_| {
        con.recv();
        while (con.io.recver.popHeader(&env.env)) |t_id| switch (t_id.val) {
            meta.index(.event, way.protocol.wayland.wl_registry.Event.global).?.val => {
                const x = con.io.recver.popOp(way.protocol.wayland.wl_registry.Event.global);
                if (x.interface.eql("wl_compositor")) {
                    con.io.sender.push(registry, way.protocol.wayland.wl_registry.Request.bind{
                        .name = x.name,
                        .id = way.types.any{
                            .interface = way.types.str.fromStr("wl_compositor"),
                            .version = 5,
                            .id = wl_compositor.id,
                        },
                    });
                    con.send();
                }
                if (x.interface.eql("xdg_wm_base")) {
                    con.io.sender.push(registry, way.protocol.wayland.wl_registry.Request.bind{
                        .name = x.name,
                        .id = way.types.any{
                            .interface = way.types.str.fromStr("xdg_wm_base"),
                            .version = 6,
                            .id = xdg_wm_base.id,
                        },
                    });
                    con.send();
                }
                if (x.interface.eql("wl_shm")) {
                    con.io.sender.push(registry, way.protocol.wayland.wl_registry.Request.bind{
                        .name = x.name,
                        .id = way.types.any{
                            .interface = way.types.str.fromStr("wl_shm"),
                            .version = 1,
                            .id = wl_shm.id,
                        },
                    });
                    con.send();
                }
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
