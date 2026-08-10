const std = @import("std");
const clb = @import("columbus");
const way = clb.way.protocol.wayland;
const xdg_shell = clb.way.protocol.xdg_shell;
const meta = clb.meta;
const types = clb.way.types;

pub inline fn initial(Op: type, x: Op, args: anytype) bool {
    switch (Op) {
        way.wl_registry.Event.global => {
            args.reg_binder.bind(x, "wl_compositor", 5, args.wl_compositor.id);
            args.reg_binder.bind(x, "xdg_wm_base", 6, args.xdg_wm_base.id);
            args.reg_binder.bind(x, "wl_shm", 1, args.wl_shm.id);
            // std.debug.print("global name: {} version: {} interface: {f}\n", .{ x.name, x.version, x.interface });
        },
        way.wl_callback.Event.done => {
            std.debug.print("done: {}\n", .{x.callback_data});
            return false;
        },
        else => std.debug.print("Ignored Msg {}\n", .{x}),
    }
    return true;
}
pub inline fn configure(Op: type, x: Op, args: anytype) bool {
    switch (Op) {
        xdg_shell.xdg_surface.Event.configure => {
            args.con.io.sender.push(args.xdg_surface, xdg_shell.xdg_surface.Request.ack_configure{ .serial = x.serial });
            return false;
        },
        else => {},
        // else => std.debug.print("Ignored Msg {}\n", .{x}),
    }
    return true;
}
pub inline fn run(Op: type, x: Op, _: void) bool {
    switch (Op) {
        way.wl_display.Event.Error => {
            std.debug.print("Error: {f}\n", .{x.message});
        },
        xdg_shell.xdg_toplevel.Event.close => {
            std.debug.print("Closing window!\n", .{});
            return false;
        },
        else => std.debug.print("Ignored Msg {}\n", .{x}),
    }
    return true;
}

const FrameBuf = struct {
    const Pixel = [4]u8;
    fd: std.os.linux.fd_t,
    size: [2]i32,
    byte_size: i32,
    pub fn init() @This() {
        const size = [2]i32{ 128, 128 };
        const framebuffer_byte_size = size[0] * size[1] * @sizeOf(Pixel);

        const fd: std.os.linux.fd_t = @intCast(std.os.linux.memfd_create("framebuffer", 0));
        _ = std.os.linux.ftruncate(fd, framebuffer_byte_size);

        const OPAQUE_BLACK = [4]u8{ 0, 0, 0, 0xFF };
        const memory: *[framebuffer_byte_size]u8 = @ptrFromInt(std.os.linux.mmap(null, framebuffer_byte_size, .{ .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0));
        const pixels: []Pixel = std.mem.bytesAsSlice(Pixel, memory);
        @memset(pixels, OPAQUE_BLACK);
        for (0..64) |i| for (0..64) |j| {
            pixels[i * 128 + j] = [4]u8{ 0xFF, 0, 0, 0xFF };
            pixels[i * 128 + j + 64] = [4]u8{ 0, 0, 0, 0 };
        };
        return .{ .fd = fd, .size = size, .byte_size = framebuffer_byte_size };
    }
    pub fn deinit(self: @This()) void {
        _ = std.os.linux.close(self.fd);
    }
};

pub fn main(init: std.process.Init) !void {
    var env = clb.Env.init();
    const display = env.new(way.wl_display);
    const registry = env.new(way.wl_registry);
    const wl_callback = env.new(way.wl_callback);
    var con = try clb.Connection.initDefault(init);
    con.io.sender.push(display, way.wl_display.Request.get_registry{ .registry = registry });
    con.io.sender.push(display, way.wl_display.Request.sync{ .callback = wl_callback });
    con.send();
    var reg_binder = clb.RegistryBinder.init(&con, registry);

    const wl_compositor = env.new(way.wl_compositor);
    const wl_shm = env.new(way.wl_shm);
    const xdg_wm_base = env.new(xdg_shell.xdg_wm_base);
    try clb.loop(&con, &env, &init, .{
        .reg_binder = &reg_binder,
        .wl_compositor = wl_compositor,
        .xdg_wm_base = xdg_wm_base,
        .wl_shm = wl_shm,
    }, initial);

    const wl_surface = env.new(way.wl_surface);
    const xdg_surface = env.new(xdg_shell.xdg_surface);
    const xdg_toplenel = env.new(xdg_shell.xdg_toplevel);
    con.io.sender.push(wl_compositor, way.wl_compositor.Request.create_surface{ .id = wl_surface });
    con.io.sender.push(xdg_wm_base, xdg_shell.xdg_wm_base.Request.get_xdg_surface{ .id = xdg_surface, .surface = wl_surface.id });
    con.io.sender.push(xdg_surface, xdg_shell.xdg_surface.Request.get_toplevel{ .id = xdg_toplenel });
    con.io.sender.push(wl_surface, way.wl_surface.Request.commit{});
    con.send();
    try std.Io.sleep(init.io, .fromMilliseconds(50), .real); // too fast otherwise

    try clb.loop(&con, &env, &init, .{
        .con = &con,
        .xdg_surface = xdg_surface,
    }, configure);

    const wl_shm_pool = env.new(way.wl_shm_pool);
    const wl_buffer = env.new(way.wl_buffer);
    // con.io.sender.push(wl_compositor, way.wl_compositor.Request.create_surface{ .id = wl_surface });
    const winbuf = FrameBuf.init();
    con.io.sender.push(wl_shm, way.wl_shm.Request.create_pool{
        .id = wl_shm_pool,
        .fd = .{ .fd = winbuf.fd },
        .size = winbuf.byte_size,
    });
    con.io.sender.push(wl_shm_pool, way.wl_shm_pool.Request.create_buffer{
        .id = wl_buffer,
        .offset = 0,
        .width = winbuf.size[0],
        .height = winbuf.size[1],
        .stride = winbuf.size[0] * @sizeOf(FrameBuf.Pixel),
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

    try clb.loop(&con, &env, &init, void{}, run);
}
