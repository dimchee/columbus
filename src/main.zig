const std = @import("std");
const clb = @import("columbus");
const way = clb.way;

const Header = extern struct { object_id: u32, opcode: u16, size: u16 };
const Len = struct { ctrl: u16, msg: u16 };
const Mem = struct {
    mem: []u8,
    fn push(self: *@This(), T: type, x: T) void {
        const bytes: []const u8 = if (T == []const u8) x else @ptrCast(@alignCast(&x));
        @memcpy(self.mem[0..bytes.len], bytes);
        self.mem = self.mem[bytes.len..];
    }
    fn read(self: *@This(), n: usize) []const u8 {
        const sol = self.mem[0..n];
        self.mem = self.mem[n..];
        return sol;
    }
    fn readT(self: *@This(), T: type) T {
        return std.mem.bytesToValue(T, self.read(@sizeOf(T)));
    }
    pub fn aligned(len: u64) u16 {
        return std.mem.alignForward(u16, @intCast(len), @sizeOf(u32));
    }
};
pub fn aligned(len: u64) u16 {
    return std.mem.alignForward(u16, @intCast(len), @sizeOf(u32));
}
pub fn send(socket: std.posix.socket_t, alloc: std.mem.Allocator, sender: anytype, msg: anytype) !void {
    const len = x: {
        var len = Len{ .ctrl = 0, .msg = @sizeOf(Header) };
        inline for (@typeInfo(@TypeOf(msg)).@"struct".fields) |field| {
            const f = @field(msg, field.name);
            switch (field.type) { // TODO solve magic numbers
                i32, u32 => len.msg += @sizeOf(i32),
                []const u8 => len.msg += 4 + aligned(f.len + 1),
                way.fd => len.ctrl += 20, // TODO why?
                way.any => len.msg += 4 + aligned(f.interface.len + 1) + 4 + 4,
                inline else => |X| if (comptime @hasDecl(X, "Protocol") or @hasDecl(X, "Interface")) {
                    len.msg += @sizeOf(X);
                } else @compileError(@typeName(X) ++ " is not Enum, nor Interface"),
            }
        }
        break :x len;
    };
    const data = .{ try alloc.alloc(u8, len.msg), try alloc.alloc(u8, len.ctrl) };
    var mem = .{ .msg = Mem{ .mem = data[0] }, .ctrl = Mem{ .mem = data[1] } };
    mem.msg.push(Header, .{
        .object_id = sender.id,
        .opcode = @TypeOf(msg).Opcode,
        .size = len.msg,
    });
    inline for (@typeInfo(@TypeOf(msg)).@"struct".fields) |field| {
        const f = @field(msg, field.name);
        switch (field.type) {
            i32, u32 => mem.msg.push(field.type, f),
            []const u8 => {
                mem.msg.push(u32, @intCast(f.len + 1));
                mem.msg.push([]const u8, f.data);
                for (0..(Mem.aligned(f.len + 1) - f.len)) |_|
                    mem.msg.push("\x00");
            },
            way.any => {
                const str = f.interface;
                mem.msg.push(u32, @intCast(str.len + 1));
                mem.msg.push([]const u8, str);
                for (0..(Mem.aligned(str.len + 1) - str.len)) |_|
                    mem.msg.push([]const u8, "\x00");
                mem.msg.push(u32, f.version);
                mem.msg.push(u32, f.id);
            },
            inline else => |X| if (comptime @hasDecl(X, "Protocol")) {
                mem.msg.push(u32, f.id);
            } else if (comptime @hasDecl(X, "Interface")) {
                mem.msg.push(X, f);
            } else @compileError(@typeName(X) ++ " is not writable"),
        }
        std.debug.assert(mem.msg.mem.len == 0);
        std.debug.assert(mem.ctrl.mem.len == 0);
    }

    const msghdr = std.posix.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &[_]std.posix.iovec_const{.{ .base = data[0].ptr, .len = data[0].len }},
        .iovlen = 1,
        .control = data[1].ptr,
        .controllen = data[1].len,
        .flags = 0,
    };
    if (std.os.linux.sendmsg(socket, &msghdr, 0) < len.msg)
        @panic("Impossible");
}

// pub fn read(alloc: std.mem.Allocator, socket: std.posix.socket_t) !@This() {
//     var buf = struct { msg: [1024]u8, ctrl: [1024]u8 }{ .msg = undefined, .ctrl = undefined };
//     var msg_iov = [_]std.posix.iovec{.{ .base = &buf.msg, .len = buf.msg.len }};
//     var msg_hdr = std.posix.msghdr{
//         .name = null,
//         .namelen = 0,
//         .iov = &msg_iov,
//         .iovlen = msg_iov.len,
//         .control = &buf.ctrl,
//         .controllen = buf.ctrl.len,
//         .flags = 0,
//     };
//
//     const Mode = enum { readHeader, readMsg };
//     var mode = Mode.readHeader;
//     var header: Header = undefined;
//     var mem = .{ .msg = Mem{ .mem = "" }, .ctrl = Mem{ .mem = "" } };
//     while (true) {
//         const len: isize = @bitCast(std.os.linux.recvmsg(socket, &msg_hdr, std.os.linux.MSG.DONTWAIT));
//         const WOULDBLOCK: isize = -11;
//         if (len == WOULDBLOCK) break else if (len < 0) return error.recvmsg;
//         if (len == 0) break;
//         const data = try alloc.alloc(u8, mem.msg.mem.len + @abs(len));
//         @memcpy(data[0..mem.msg.mem.len], mem.msg.mem);
//         @memcpy(data[mem.msg.mem.len..], buf.msg[0..@abs(len)]);
//         mem.msg.mem = data;
//         mem.ctrl.mem = buf.ctrl[0..msg_hdr.controllen];
//         while (true) switch (mode) {
//             .readHeader => {
//                 if (mem.msg.mem.len < @sizeOf(Header)) break;
//                 header = mem.msg.readT(Header);
//                 mode = .readMsg;
//             },
//             .readMsg => {
//                 if (mem.msg.mem.len + @sizeOf(Header) < header.size) break;
//                 const msg = try fromBytes(env, header, &mem);
//                 try msgs.append(arena.allocator(), msg);
//                 mode = .readHeader;
//             },
//         };
//     }
// }

pub fn main(init: std.process.Init) !void {
    const soc = try init_display(init);
    const alloc = init.arena.allocator();

    const display = way.wayland.wl_display{ .id = 1 };
    const registry = way.wayland.wl_registry{ .id = 2 };
    const wl_callback = way.wayland.wl_callback{ .id = 3 };
    try send(soc, alloc, display, way.wayland.wl_display.Request.get_registry{ .registry = registry });
    try send(soc, alloc, display, way.wayland.wl_display.Request.sync{ .callback = wl_callback });
    // loop: while (true) {
    //     var r = try env.read(.servertoclient);
    //     defer r.deinit();
    //     for (r.msgs) |msg| switch (msg) {
    //         .wayland => |protocol| switch (protocol) {
    //             .wl_registry => |interface| switch (interface) {
    //                 .global => |x| {
    //                     std.debug.print("global name: {} version: {} interface: {s}\n", .{ x.name, x.version, x.interface });
    //                 },
    //                 else => {},
    //             },
    //             .wl_callback => |interface| switch (interface) {
    //                 else => break :loop,
    //             },
    //             else => {},
    //         },
    //         else => {},
    //     };
    // }
}
fn init_display(pInit: std.process.Init) !std.posix.socket_t {
    const display_path = try x: {
        const xdg_runtime_dir = pInit.environ_map.get("XDG_RUNTIME_DIR") orelse
            break :x error.NoXdgRuntimeDir;
        const display_name = pInit.environ_map.get("WAYLAND_DISPLAY") orelse "wayland-0";
        break :x try std.fs.path.join(pInit.gpa, &.{ xdg_runtime_dir, display_name });
    };
    defer pInit.gpa.free(display_path);
    return x: {
        const sockfd: std.os.linux.fd_t = @intCast(std.os.linux.socket(
            std.os.linux.AF.UNIX,
            std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC,
            0,
        ));
        errdefer _ = std.os.linux.close(sockfd);

        const addr = a: {
            var sock_addr = std.os.linux.sockaddr.un{
                .family = std.os.linux.AF.UNIX,
                .path = undefined,
            };
            // Add 1 to ensure a terminating 0 is present in the path array for maximum portability.
            if (display_path.len + 1 > sock_addr.path.len) return error.NameTooLong;
            @memset(&sock_addr.path, 0);
            @memcpy(sock_addr.path[0..display_path.len], display_path);
            break :a sock_addr;
        };
        // std.posix.AF.UNIX len
        const soc_len = @as(std.os.linux.socklen_t, @intCast(@sizeOf(std.os.linux.sockaddr.un)));
        _ = std.os.linux.connect(sockfd, @ptrCast(&addr), soc_len);
        break :x sockfd;
    };
}
