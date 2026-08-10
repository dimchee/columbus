const std = @import("std");
const clb = @import("columbus");
const way = clb.way.protocol.wayland;
const xdg_shell = clb.way.protocol.xdg_shell;
const meta = clb.meta;
const types = clb.way.types;

pub fn main(init: std.process.Init) !void {
    var env = clb.Env.init();
    const display = env.new(way.wl_display);
    const registry = env.new(way.wl_registry);
    const wl_callback = env.new(way.wl_callback);
    var con = try clb.Connection.initDefault(init);
    con.io.sender.push(display, way.wl_display.Request.get_registry{ .registry = registry });
    con.io.sender.push(display, way.wl_display.Request.sync{ .callback = wl_callback });
    con.send();
    var reg = clb.RegistryBinder.init(&con, registry);

    const wl_compositor = env.new(way.wl_compositor);
    const wl_shm = env.new(way.wl_shm);
    const xdg_wm_base = env.new(xdg_shell.xdg_wm_base);
    try std.Io.sleep(init.io, .fromMilliseconds(50), .real); // too fast otherwise
    loop: while (true) {
        con.recv();
        while (con.io.recver.popHeader(&env.env)) |t_id| switch (t_id.val) {
            meta.index(.event, way.wl_registry.Event.global).?.val => {
                const x = con.io.recver.popOp(way.wl_registry.Event.global);
                reg.interface_bind(x, "wl_compositor", 5, wl_compositor.id);
                reg.interface_bind(x, "xdg_wm_base", 6, xdg_wm_base.id);
                reg.interface_bind(x, "wl_shm", 1, wl_shm.id);
                // std.debug.print("global name: {} version: {} interface: {f}\n", .{ x.name, x.version, x.interface });
            },
            meta.index(.event, way.wl_callback.Event.done).?.val => {
                const x = con.io.recver.popOp(way.wl_callback.Event.done);
                std.debug.print("done: {}\n", .{x.callback_data});
                break :loop;
            },
            meta.lists.events.types.len...std.math.maxInt(usize) => unreachable,
            inline else => |i| {
                const msg = con.io.recver.popOp(meta.lists.events.types[i]);
                std.debug.print("Ignored Msg {}\n", .{msg});
            },
        };
    }

    const wl_surface = env.new(way.wl_surface);
    const xdg_surface = env.new(xdg_shell.xdg_surface);
    const xdg_toplenel = env.new(xdg_shell.xdg_toplevel);
    con.io.sender.push(wl_compositor, way.wl_compositor.Request.create_surface{ .id = wl_surface });
    con.io.sender.push(xdg_wm_base, xdg_shell.xdg_wm_base.Request.get_xdg_surface{ .id = xdg_surface, .surface = wl_surface.id });
    con.io.sender.push(xdg_surface, xdg_shell.xdg_surface.Request.get_toplevel{ .id = xdg_toplenel });
    con.io.sender.push(wl_surface, way.wl_surface.Request.commit{});
    con.send();
    try std.Io.sleep(init.io, .fromMilliseconds(50), .real); // too fast otherwise

    loop: while (true) {
        con.recv();
        while (con.io.recver.popHeader(&env.env)) |t_id| switch (t_id.val) {
            meta.index(.event, xdg_shell.xdg_surface.Event.configure).?.val => {
                const x = con.io.recver.popOp(xdg_shell.xdg_surface.Event.configure);
                con.io.sender.push(xdg_surface, xdg_shell.xdg_surface.Request.ack_configure{ .serial = x.serial });
                break :loop;
            },
            meta.lists.events.types.len...std.math.maxInt(usize) => unreachable,
            inline else => |i| {
                const msg = con.io.recver.popOp(meta.lists.events.types[i]);
                _ = msg;
                // std.debug.print("Ignored Msg {} {}\n", .{ @TypeOf(msg), msg });
            },
        };
    }

    const Pixel = [4]u8;
    const size = [2]i32{ 128, 128 };
    const framebuffer_byte_size = size[0] * size[1] * @sizeOf(Pixel);

    const fd: std.os.linux.fd_t = @intCast(std.os.linux.memfd_create("framebuffer", 0));
    defer _ = std.os.linux.close(fd);
    _ = std.os.linux.ftruncate(fd, framebuffer_byte_size);

    const OPAQUE_BLACK = [4]u8{ 0, 0, 0, 0xFF };
    const memory: *[framebuffer_byte_size]u8 = @ptrFromInt(std.os.linux.mmap(null, framebuffer_byte_size, .{ .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0));
    const pixels: []Pixel = std.mem.bytesAsSlice(Pixel, memory);
    @memset(pixels, OPAQUE_BLACK);
    for (0..64) |i| for (0..64) |j| {
        pixels[i * 128 + j] = [4]u8{ 0xFF, 0, 0, 0xFF };
        pixels[i * 128 + j + 64] = [4]u8{ 0, 0, 0, 0 };
    };

    const wl_shm_pool = env.new(way.wl_shm_pool);
    const wl_buffer = env.new(way.wl_buffer);
    // con.io.sender.push(wl_compositor, way.wl_compositor.Request.create_surface{ .id = wl_surface });
    con.io.sender.push(wl_shm, way.wl_shm.Request.create_pool{
        .id = wl_shm_pool,
        .fd = .{ .fd = fd },
        .size = framebuffer_byte_size,
    });
    con.io.sender.push(wl_shm_pool, way.wl_shm_pool.Request.create_buffer{
        .id = wl_buffer,
        .offset = 0,
        .width = size[0],
        .height = size[1],
        .stride = size[0] * @sizeOf(Pixel),
        .format = .argb8888,
    });
    con.io.sender.push(wl_surface, way.wl_surface.Request.attach{
        .buffer = wl_buffer.id,
        .x = 0,
        .y = 0,
    });
    con.io.sender.push(wl_surface, way.wl_surface.Request.damage{ .x = 0, .y = 0, .width = std.math.maxInt(i32), .height = std.math.maxInt(i32) });
    con.io.sender.push(wl_surface, way.wl_surface.Request.commit{});
    con.send();

    loop: while (true) {
        try std.Io.sleep(init.io, .fromMilliseconds(160), .real); // too fast otherwise
        con.recv();
        while (con.io.recver.popHeader(&env.env)) |t_id| switch (t_id.val) {
            meta.lists.events.types.len...std.math.maxInt(usize) => unreachable,
            meta.index(.event, way.wl_display.Event.Error).?.val => {
                const msg = con.io.recver.popOp(way.wl_display.Event.Error);
                std.debug.print("Error: {f}\n", .{msg.message});
            },
            meta.index(.event, xdg_shell.xdg_toplevel.Event.close).?.val => {
                _ = con.io.recver.popOp(xdg_shell.xdg_toplevel.Event.close);
                std.debug.print("Closing window!\n", .{});
                break :loop;
            },
            inline else => |i| {
                const msg = con.io.recver.popOp(meta.lists.events.types[i]);
                std.debug.print("Ignored Msg {} {}\n", .{ @TypeOf(msg), msg });
            },
        };
    }
}
