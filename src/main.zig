const std = @import("std");
const clb = @import("columbus");
const way = clb.way;
const meta = clb.meta;
const Str = way.types.str;

// TODO Something like:
// Env.register(struct {
//     // Must be marked pub
//     pub fn print_global(x: way.wayland.wl_registry.Event.global) void {
//         std.debug.print("global name: {} version: {} interface: {s}\n", .{ x.name, x.version, x.interface });
//     }
// });
//

// TODO what if one read overflows?
// TODO check if .head == 0 and .tail == 0 cases are handled
/// From wayland-private.h
pub fn RingBuffer(comptime CAPACITY: usize) type {
    return struct {
        data: [CAPACITY]u8,
        head: usize,
        len: usize,
        pub fn init() @This() {
            return .{ .data = undefined, .head = 0, .len = 0 };
        }
        const View = struct { main: []u8, wrap: []u8 };
        fn view_const(self: *const @This(), head: usize, len: usize) way.types.str {
            return if (head + len < self.data.len)
                .{ .main = self.data[head .. head + len], .wrap = "" }
            else
                .{ .main = self.data[head..self.data.len], .wrap = self.data[0 .. head + len - self.data.len] };
        }
        fn view(self: *@This(), head: usize, len: usize) View {
            return if (head + len < self.data.len)
                .{ .main = self.data[head .. head + len], .wrap = "" }
            else
                .{ .main = self.data[head..self.data.len], .wrap = self.data[0 .. head + len - self.data.len] };
        }
        pub fn put(self: *@This(), bytes: []const u8) void {
            if (self.data.len < self.len + bytes.len) @panic("Can't put - RingBuffer too long");
            const tail = @min(self.head + self.len -% self.data.len, self.head + self.len);
            const str = self.view(tail, bytes.len);
            @memcpy(str.main, bytes.ptr);
            if (0 < str.wrap.len) @memcpy(str.wrap, bytes[str.main.len..].ptr);
            self.len += bytes.len;
        }
        fn DeferedPut(T: type) type {
            return struct {
                view: View,
                fn put(self: @This(), x: T) void {
                    const bytes: []const u8 = @ptrCast(&x);
                    @memcpy(self.view.main, bytes.ptr);
                    if (0 < self.view.wrap.len) @memcpy(self.view.wrap, bytes[self.view.main.len..].ptr);
                }
            };
        }
        pub fn putTDefered(self: *@This(), T: type) DeferedPut(T) {
            if (self.data.len < self.len + @sizeOf(T)) @panic("Can't put - RingBuffer too long");
            const tail = @min(self.head + self.len -% self.data.len, self.head + self.len);
            self.len += @sizeOf(T);
            return .{ .view = self.view(tail, @sizeOf(T)) };
        }
        pub fn peek(self: *@This(), bytes: []u8) void {
            if (self.len < bytes.len) @panic("can't get - ringbuffer too short");
            const str = self.view(self.head, bytes.len);
            @memcpy(bytes.ptr, str.main);
            if (0 < str.wrap.len) @memcpy(bytes[str.main.len..].ptr, str.wrap);
        }
        pub fn peekT(self: *@This(), T: type) T {
            var x: T = undefined;
            self.peek(@ptrCast(&x));
            return x;
        }
        pub fn get(self: *@This(), bytes: []u8) void {
            self.peek(bytes);
            self.head = @min(self.head + bytes.len -% self.data.len, self.head + bytes.len);
            self.len -= bytes.len;
        }
        pub fn getN(self: *@This(), n: usize) way.types.str {
            if (self.len < n) @panic("Can't get - RingBuffer too short");
            const sol = self.view(self.head, n);
            self.len -= n;
            self.head = @min(self.head + n -% self.data.len, self.head + n);
            return .{ .main = sol.main, .wrap = sol.wrap };
        }
        pub fn putN(self: *@This(), n: usize) void {
            if (self.data.len < self.len + n) @panic("Can't put - RingBuffer too long");
            self.len += n;
        }
        pub fn putT(self: *@This(), T: type, x: T) void {
            self.put(@ptrCast(&x));
        }
        pub fn getT(self: *@This(), T: type) T {
            var x: T = undefined;
            self.get(@ptrCast(&x));
            return x;
        }
        pub fn as_str(self: *const @This()) way.types.str {
            return self.view_const(self.head, self.len);
        }
        pub fn as_iovec_const(self: *const @This()) [2]std.posix.iovec_const {
            const x = self.view_const(self.head, self.len);
            return .{ .{ .base = x.main.ptr, .len = x.main.len }, .{ .base = x.wrap.ptr, .len = x.wrap.len } };
        }
        pub fn as_iovec(self: *@This()) [2]std.posix.iovec {
            const tail = @min(self.head + self.len -% self.data.len, self.head + self.len);
            const x = self.view(tail, self.data.len - self.len);
            return .{ .{ .base = x.main.ptr, .len = x.main.len }, .{ .base = x.wrap.ptr, .len = x.wrap.len } };
        }
    };
}

const Header = extern struct { object_id: u32, opcode: u16, size: u16 };
const Connection = struct {
    // std.Io.Writer.fixed
    io: struct { recver: Recver, sender: Sender },
    socket: std.posix.socket_t,
    pub fn init(socket: std.posix.socket_t) @This() {
        return .{ .io = .{ .recver = .init(), .sender = .init() }, .socket = socket };
    }
    pub fn send(self: *@This()) void {
        if (std.os.linux.sendmsg(self.socket, &std.posix.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &self.io.sender.msg.as_iovec_const(),
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        }, 0) < self.io.sender.msg.len) @panic("Impossible");
        _ = self.io.sender.msg.getN(self.io.sender.msg.len);
    }
    /// This function invalidates last recv msgs
    pub fn recv(self: *@This()) void {
        var msg_iov = self.io.recver.msg.as_iovec();
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
    const Recver = struct {
        msg: RingBuffer(1 << 6), // WL_BUFFER_DEFAULT_SIZE_POT = 12, WL_BUFFER_DEFAULT_MAX_SIZE = (1 << WL_BUFFER_DEFAULT_SIZE_POT)
        ctrl: [1024]u8,
        fn init() @This() {
            return .{ .msg = .init(), .ctrl = undefined };
        }
        fn readOp(self: *@This(), Op: type) Op {
            var op: Op = undefined;
            inline for (@typeInfo(Op).@"struct".fields) |field| {
                switch (field.type) {
                    i32, u32 => @field(op, field.name) = self.msg.getT(field.type),
                    way.types.str => {
                        const len = self.msg.getT(u32);
                        @field(op, field.name) = self.msg.getN(len - 1);
                        _ = self.msg.getN(aligned(len) - len + 1);
                    },
                    way.types.array => {
                        const len = self.msg.getT(u32);
                        @field(op, field.name) = .{ .data = self.msg.getN(len - 1) };
                        _ = self.msg.getN(aligned(len) - len + 1);
                    },
                    way.types.fd => {
                        _ = self.msg.getT(struct { u64, i32, i32 }); // _, std.posix.SOL.SOCKET, 0x01
                        // self.msg = self.msg[@sizeOf(u64) + @sizeOf(i32) + @sizeOf(i32) ..];
                        // @field(op, field.name) = .{ .fd = self.msg.getT(i32, &self.ctrl) }; // TODO not handling ctrl
                    },
                    inline else => |X| switch (comptime meta.getKind(X)) {
                        .interface => @panic("ToDoInterface"),
                        .@"enum" => @panic("ToDoEnum"),
                        // @field(op, field.name) = self.msg.getT(field.type, &self.msg);
                        else => @compileError(@typeName(X) ++ " is not readable"),
                    },
                }
            }
            return op;
        }
        const Read = struct { type_id: meta.Index(.event), bytes: []u8 };
        pub fn pop(self: *@This(), alloc: std.mem.Allocator, env: *Env) ?Read {
            if (self.msg.len < @sizeOf(Header)) return null;
            const header = self.msg.peekT(Header);
            if (self.msg.len < header.size) return null else _ = self.msg.getT(Header);
            switch (env.env[header.object_id].val) {
                meta.lists.interfaces.len...std.math.maxInt(usize) => unreachable,
                inline else => |ind| {
                    const I = meta.lists.interfaces[ind];
                    const ops = @typeInfo(I.Event).@"struct".decls;
                    if (ops.len == 0) @panic("ops.len == 0");
                    switch (header.opcode) {
                        ops.len...std.math.maxInt(@TypeOf(header.opcode)) => unreachable,
                        inline else => |op_id| {
                            const Op = @field(I.Event, ops[op_id].name);
                            const op = alloc.create(Op) catch @panic("Couldn't allocate");
                            op.* = self.readOp(Op);
                            return Read{ .bytes = @ptrCast(op), .type_id = comptime meta.index(.event, Op).? };
                        },
                    }
                },
            }
        }
    };
    const Sender = struct {
        msg: RingBuffer(1 << 6), // WL_BUFFER_DEFAULT_SIZE_POT = 12, WL_BUFFER_DEFAULT_MAX_SIZE = (1 << WL_BUFFER_DEFAULT_SIZE_POT)
        ctrl: [1024]u8,
        fn init() @This() {
            return .{ .msg = .init(), .ctrl = undefined };
        }
        pub fn pushStr(self: *@This(), str: way.types.str) void {
            self.msg.putT(u32, @intCast(str.len + 1));
            self.msg.put(str.data);
            for (0..(aligned(str.len + 1) - str.len)) |_| {
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
                    way.types.str => self.pushStr(f),
                    way.types.any => {
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
};

const Env = struct {
    env: [64]meta.Index(.interface), // Maps id to TypeId
    id: u32,
    fn init() @This() {
        return .{ .id = 0, .env = undefined };
    }
    fn new(self: *@This(), X: type) X {
        self.id += 1;
        self.env[self.id] = comptime meta.index(.interface, X).?;
        return .{ .id = self.id };
    }
};

fn init_display(pInit: std.process.Init) !std.posix.socket_t {
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
    return sockfd;
}

pub fn main(init: std.process.Init) !void {
    const soc = try init_display(init);
    const alloc = init.arena.allocator();

    var env = Env.init();
    const display = env.new(way.wayland.wl_display);
    const registry = env.new(way.wayland.wl_registry);
    const wl_callback = env.new(way.wayland.wl_callback);
    var con = Connection.init(soc);
    con.io.sender.push(display, way.wayland.wl_display.Request.get_registry{ .registry = registry });
    con.io.sender.push(display, way.wayland.wl_display.Request.sync{ .callback = wl_callback });
    con.send();
    try std.Io.sleep(init.io, .fromMilliseconds(50), .real); // too fast otherwise
    // const rs = try read(alloc, &env, soc);
    for (1..40) |_| {
        con.recv();
        while (con.io.recver.pop(alloc, &env)) |r| switch (r.type_id.val) {
            meta.index(.event, way.wayland.wl_registry.Event.global).?.val => {
                const x: *way.wayland.wl_registry.Event.global = @ptrCast(@alignCast(r.bytes));
                std.debug.print("global name: {} version: {} interface: {f}\n", .{ x.name, x.version, x.interface });
            },
            meta.lists.events.types.len...std.math.maxInt(usize) => unreachable,
            inline else => |i| std.debug.print("Ignored Msg {s}\n", .{@typeName(meta.lists.events.types[i])}),
        };
    }
    // std.debug.print("{f}", .{Str{ .data = .{ "Test", "Ing" } }});
}
