const std = @import("std");
const rb = @import("ringbuffer.zig");
const types = @import("types.zig");
const meta = @import("meta.zig");
// std.Io.Writer.fixed
io: struct { recver: Recver, sender: Sender },
socket: std.posix.socket_t,
pub fn initDefault(pInit: std.process.Init) !@This() {
    const xdg_runtime_dir = pInit.environ_map.get("XDG_RUNTIME_DIR") orelse
        return error.NoXdgRuntimeDir;
    const display_name = pInit.environ_map.get("WAYLAND_DISPLAY") orelse "wayland-0";
    const display_path = try std.fs.path.join(pInit.gpa, &.{ xdg_runtime_dir, display_name });
    defer pInit.gpa.free(display_path);
    const sockfd: std.os.linux.fd_t = @intCast(std.os.linux.socket(
        std.os.linux.AF.UNIX,
        std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC,
        0,
    ));
    errdefer _ = std.os.linux.close(sockfd);
    var sock_addr = std.os.linux.sockaddr.un{
        .family = std.os.linux.AF.UNIX,
        .path = undefined,
    };
    if (display_path.len + 1 > sock_addr.path.len) return error.NameTooLong; // +1 for c_string
    @memset(&sock_addr.path, 0);
    @memcpy(sock_addr.path[0..display_path.len], display_path);
    // std.posix.AF.UNIX len
    const soc_len: std.os.linux.socklen_t = @intCast(@sizeOf(std.os.linux.sockaddr.un));
    _ = std.os.linux.connect(sockfd, @ptrCast(&sock_addr), soc_len);
    return .init(sockfd);
}
pub fn init(socket: std.posix.socket_t) @This() {
    return .{ .io = .{ .recver = .init(), .sender = .init() }, .socket = socket };
}
pub fn send(self: *@This()) void {
    while (self.io.sender.msg.len != 0) {
        const x = self.io.sender.msg.used();
        const sent = std.os.linux.sendmsg(self.socket, &std.posix.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &.{ .{ .base = x.main.ptr, .len = x.main.len }, .{ .base = x.wrap.ptr, .len = x.wrap.len } },
            .iovlen = 1,
            .control = &self.io.sender.ctrl,
            .controllen = self.io.sender.ctrl_len,
            .flags = 0,
        }, 0);
        _ = self.io.sender.msg.getN(sent);
    }
}
/// This function invalidates last recv msgs
pub fn recv(self: *@This()) void {
    const x = self.io.recver.msg.free();
    var msg_iov = [_]std.posix.iovec{ .{ .base = x.main.ptr, .len = x.main.len }, .{ .base = x.wrap.ptr, .len = x.wrap.len } };
    var msg_hdr = std.posix.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &msg_iov,
        .iovlen = msg_iov.len,
        .control = &self.io.recver.ctrl,
        .controllen = self.io.recver.ctrl.len,
        .flags = 0,
    };
    // TODO if msg overflows (`len == buf.msg.len`), read again
    const len = std.os.linux.recvmsg(self.socket, &msg_hdr, std.os.linux.MSG.DONTWAIT);
    const WOULDBLOCK: usize = @bitCast(@as(isize, -11)); // TODO does it work?
    if (len == WOULDBLOCK) {
        std.debug.print("wouldblock?\n", .{});
        return;
    }
    self.io.recver.msg.putN(len);
}
pub fn aligned(len: u64) u16 {
    return std.mem.alignForward(u16, @intCast(len), @sizeOf(u32));
}
const Header = extern struct { object_id: u32, opcode: u16, size: u16 };
const Sender = struct {
    msg: rb.RingBuffer(1 << 12), // WL_BUFFER_DEFAULT_SIZE_POT = 12, WL_BUFFER_DEFAULT_MAX_SIZE = (1 << WL_BUFFER_DEFAULT_SIZE_POT)
    ctrl: [1024]u8,
    ctrl_len: usize,
    fn init() @This() {
        return .{ .msg = .init(), .ctrl = undefined, .ctrl_len = 0 };
    }
    pub fn pushStr(self: *@This(), str: types.str) void {
        const len = str.len();
        self.msg.putT(u32, @intCast(len + 1));
        self.msg.put(str.main);
        self.msg.put(str.wrap);
        for (0..(aligned(len + 1) - len)) |_| {
            self.msg.put("\x00");
        }
    }
    pub fn push(self: *@This(), sender: anytype, msg: anytype) void {
        const start_len = self.msg.len;
        const header_defered = self.msg.putTDefered(Header);
        inline for (@typeInfo(@TypeOf(msg)).@"struct".fields) |field| {
            const f = @field(msg, field.name);
            switch (field.type) {
                i32, u32 => self.msg.putT(field.type, f),
                types.str => self.pushStr(f),
                types.fd => {
                    // @panic("TodoFD");
                    const SCM_RIGHTS = 0x01; // from <bits/socket.h> in <sys/socket.h>
                    const FD = extern struct { size: u64 align(4), sol: i32, rights: i32, fd: std.posix.fd_t };
                    @memcpy(self.ctrl[0..@sizeOf(FD)], @as([]const u8, @ptrCast(&FD{
                        .size = @sizeOf(FD),
                        .sol = std.posix.SOL.SOCKET,
                        .rights = SCM_RIGHTS,
                        .fd = f.fd,
                    })));
                    self.ctrl_len += @sizeOf(FD);
                },
                types.any => {
                    self.pushStr(f.interface);
                    self.msg.putT(u32, f.version);
                    self.msg.putT(u32, f.id);
                },
                inline else => |X| switch (comptime meta.getKind(X)) {
                    .interface => self.msg.putT(u32, f.id),
                    .@"enum" => self.msg.putT(X, f),
                    else => @compileError(@typeName(X) ++ " is not Enum, nor Interface"),
                },
            }
        }
        header_defered.put(.{
            .object_id = sender.id,
            .opcode = meta.opcode(@TypeOf(msg)),
            .size = @intCast(self.msg.len - start_len),
        });
    }
};
const Recver = struct {
    msg: rb.RingBuffer(1 << 12), // WL_BUFFER_DEFAULT_SIZE_POT = 12, WL_BUFFER_DEFAULT_MAX_SIZE = (1 << WL_BUFFER_DEFAULT_SIZE_POT)
    ctrl: [1024]u8,
    fn init() @This() {
        return .{ .msg = .init(), .ctrl = undefined };
    }
    pub fn popOp(self: *@This(), Op: type) Op {
        var op: Op = undefined;
        inline for (@typeInfo(Op).@"struct".fields) |field| {
            switch (field.type) {
                i32, u32 => @field(op, field.name) = self.msg.getT(field.type),
                types.str => {
                    const len = self.msg.getT(u32);
                    if (len != 0) {
                        const vw = self.msg.getN(len - 1);
                        @field(op, field.name) = .{ .main = vw.main, .wrap = vw.wrap };
                        _ = self.msg.getN(aligned(len) - len + 1);
                    } else @field(op, field.name) = .{ .main = "", .wrap = "" };
                },
                types.array => {
                    const len = self.msg.getT(u32);
                    if (len != 0) {
                        const vw = self.msg.getN(len - 1);
                        @field(op, field.name) = .{ .data = .{ .main = vw.main, .wrap = vw.wrap } };
                        _ = self.msg.getN(aligned(len) - len + 1);
                    } else @field(op, field.name) = .{ .data = .{ .main = "", .wrap = "" } };
                },
                types.fd => {
                    @panic("ToDoFD");
                    // _ = self.msg.getT(struct { u64, i32, i32 }); // _, std.posix.SOL.SOCKET, 0x01
                    // self.msg = self.msg[@sizeOf(u64) + @sizeOf(i32) + @sizeOf(i32) ..];
                    // @field(op, field.name) = .{ .fd = self.msg.getT(i32, &self.ctrl) }; // TODO not handling ctrl
                },
                inline else => |X| switch (comptime meta.getKind(X)) {
                    .interface => @panic("ToDoInterface"),
                    .@"enum" => @field(op, field.name) = self.msg.getT(field.type),
                    else => @compileError(@typeName(X) ++ " is not readable"),
                },
            }
        }
        return op;
    }
    pub fn popHeader(self: *@This(), env: []meta.Index(.interface)) ?meta.Index(.event) {
        if (self.msg.len < @sizeOf(Header)) return null;
        const header = self.msg.peekT(Header);
        if (self.msg.len < header.size) return null else _ = self.msg.getT(Header);
        switch (env[header.object_id].val) {
            meta.lists.interfaces.len...std.math.maxInt(usize) => unreachable,
            inline else => |ind| {
                const I = meta.lists.interfaces[ind];
                const ops = @typeInfo(I.Event).@"struct".decls;
                if (ops.len == 0) @panic("ops.len == 0");
                switch (header.opcode) {
                    ops.len...std.math.maxInt(@TypeOf(header.opcode)) => unreachable,
                    inline else => |op_id| return comptime meta.index(.event, @field(I.Event, ops[op_id].name)).?,
                }
            },
        }
    }
};
