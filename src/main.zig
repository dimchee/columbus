const std = @import("std");
const clb = @import("columbus");
const way = clb.way;
const meta = clb.meta;

// TODO Something like:
// Env.register(struct {
//     // Must be marked pub
//     pub fn print_global(x: way.wayland.wl_registry.Event.global) void {
//         std.debug.print("global name: {} version: {} interface: {s}\n", .{ x.name, x.version, x.interface });
//     }
// });
//
// TODO new `Str` type that has data: [2][]u8, and can get it from RingBuffer

// TODO check if .head == 0 and .tail == 0 cases are handled
/// From wayland-private.h
const RingBuffer = struct {
    data: [1 << 12]u8, // WL_BUFFER_DEFAULT_SIZE_POT = 12, WL_BUFFER_DEFAULT_MAX_SIZE = (1 << WL_BUFFER_DEFAULT_SIZE_POT)
    head: usize,
    tail: usize,
    pub fn init() @This() {
        return .{ .data = undefined, .head = 0, .tail = 0 };
    }
    pub fn len(self: @This()) usize {
        return if (self.head <= self.tail)
            self.tail - self.head
        else
            self.data.len - self.tail + self.head;
    }
    pub fn put(self: *@This(), bytes: []const u8) void {
        if (self.tail + bytes.len < self.data.len)
            @memcpy(self.data[self.tail .. self.tail + bytes.len], bytes)
        else {
            @memcpy(self.data[self.tail..self.data.len], bytes[0 .. self.data.len - self.tail]);
            @memcpy(self.data[0 .. self.data.len - self.tail], bytes[self.data.len - self.tail .. bytes.len]);
        }
        self.tail = (self.tail + bytes.len) % self.data.len;
    }
    pub fn get(self: *@This(), bytes: []u8) void {
        if (self.head + bytes.len < self.data.len)
            @memcpy(bytes, self.data[self.head .. self.head + bytes.len])
        else {
            @memcpy(bytes[0 .. self.data.len - self.head], self.data[self.head..self.data.len]);
            @memcpy(bytes[self.data.len - self.head .. bytes.len], self.data[0 .. self.data.len - self.head]);
        }
        self.head += bytes.len;
    }
    pub fn putT(self: *@This(), T: type, x: T) void {
        self.put(@ptrCast(&x));
    }
    pub fn getT(self: *@This(), T: type) T {
        var x: T = undefined;
        self.get(@ptrCast(&x));
        return x;
    }
    // TODO doesn't drain anything (change head and tail)
    pub fn as_iovec_const(self: *const @This()) [2]std.posix.iovec_const {
        const bytes = if (self.head < self.tail)
            .{ self.data[self.head..self.tail], "" }
        else
            .{ self.data[self.head..self.data.len], self.data[0..self.tail] };
        return .{
            .{ .base = bytes[0].ptr, .len = bytes[0].len },
            .{ .base = bytes[1].ptr, .len = bytes[1].len },
        };
    }
};

// This connection has ring buffer for recv and for send. Recv fills ring buffer, send empties ring buffer. You should yorself do the rest
// TODO multiple msgs `send` and `recv`
const Connection = struct {
    // std.Io.Writer.fixed
    const Buf = struct { msg: [2048]u8, ctrl: [1024]u8 };
    const Msg = struct { msg: RingBuffer, ctrl: []u8 };
    buf: struct { recv: Buf, send: Buf },
    socket: std.posix.socket_t,
    pub fn init(socket: std.posix.socket_t) @This() {
        return .{ .buf = undefined, .socket = socket };
    }
    /// This function should send Msgs allocated in buf.send
    pub fn send(self: @This(), msg: Msg) !void {
        if (std.os.linux.sendmsg(self.socket, &std.posix.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &msg.msg.as_iovec_const(),
            .iovlen = 1,
            .control = msg.ctrl.ptr,
            .controllen = msg.ctrl.len,
            .flags = 0,
        }, 0) < msg.msg.len()) @panic("Impossible");
    }
    /// This function invalidates last recv msgs
    pub fn recv(self: *@This()) !?Msg {
        var msg_iov = [_]std.posix.iovec{.{ .base = &self.buf.recv.msg, .len = self.buf.recv.msg.len }};
        var msg_hdr = std.posix.msghdr{
            .name = null,
            .namelen = 0,
            .iov = &msg_iov,
            .iovlen = msg_iov.len,
            .control = &self.buf.recv.ctrl,
            .controllen = self.buf.recv.ctrl.len,
            .flags = 0,
        };
        // TODO if msg overflows (`len == buf.msg.len`), read again
        const len = std.os.linux.recvmsg(self.socket, &msg_hdr, std.os.linux.MSG.DONTWAIT);
        const WOULDBLOCK: usize = @bitCast(@as(isize, -11)); // TODO does it work?
        if (len == WOULDBLOCK) return null else if (len < 0) return error.recvmsg;
        // if (len == 0) return error.len0;
        var sol = Msg{ .msg = RingBuffer{ .data = undefined, .head = 0, .tail = 0 }, .ctrl = self.buf.recv.ctrl[0..] };
        sol.msg.put(self.buf.recv.msg[0..len]);
        return sol;
    }
};

const MsgIt = struct {
    msg: RingBuffer,
    ctrl: []u8,
    fn init(msg: Connection.Msg) @This() {
        return .{ .msg = msg.msg, .ctrl = msg.ctrl };
    }
    fn readOp(self: *@This(), Op: type) Op {
        var op: Op = undefined;
        inline for (@typeInfo(Op).@"struct".fields) |field| {
            switch (field.type) {
                i32, u32 => @field(op, field.name) = self.msg.getT(field.type),
                []const u8 => {
                    const len = self.msg.getT(u32);
                    self.msg.get(self.ctrl[0..aligned(len)]); // TODO don't use ctrl, should be allocated
                    @field(op, field.name) = self.ctrl[0 .. len - 1]; // TODO don't use ctrl, should be allocated
                },
                // way.array => {
                //     const len = mem.self.msg.readT(u32);
                //     @field(op, field.name) = .{ .data = mem.self.msg.read(len) };
                //     _ = mem.self.msg.read(aligned(len) - len);
                // },
                way.fd => {
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
    pub fn next(self: *@This(), alloc: std.mem.Allocator, env: *Env) ?Read {
        if (self.msg.len() == 0) return null; // TODO hack
        if (self.msg.len() < @sizeOf(Header)) @panic("Impossible");
        const header = self.msg.getT(Header);
        if (self.msg.len() + @sizeOf(Header) < header.size) @panic("Impossible");
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
const Header = extern struct { object_id: u32, opcode: u16, size: u16 };
const Len = struct { ctrl: u16, msg: u16 };
pub fn aligned(len: u64) u16 {
    return std.mem.alignForward(u16, @intCast(len), @sizeOf(u32));
}

// TODO Batch sendmsg
pub fn send(socket: std.posix.socket_t, sender: anytype, msg: anytype) !void {
    const len = x: {
        var len = Len{ .ctrl = 0, .msg = @sizeOf(Header) };
        inline for (@typeInfo(@TypeOf(msg)).@"struct".fields) |field| {
            const f = @field(msg, field.name);
            switch (field.type) { // TODO solve magic numbers
                i32, u32 => len.msg += @sizeOf(i32),
                []const u8 => len.msg += 4 + aligned(f.len + 1),
                way.fd => len.ctrl += 20, // TODO why?
                way.any => len.msg += 4 + aligned(f.interface.len + 1) + 4 + 4,
                inline else => |X| if (comptime meta.is(.interface, X) or meta.is(.@"enum", X)) {
                    len.msg += @sizeOf(X);
                } else @compileError(@typeName(X) ++ " is not Enum, nor Interface"),
            }
        }
        break :x len;
    };
    var rb = RingBuffer.init();
    rb.putT(Header, .{
        .object_id = sender.id,
        .opcode = meta.opcode(@TypeOf(msg)),
        .size = len.msg,
    });
    inline for (@typeInfo(@TypeOf(msg)).@"struct".fields) |field| {
        const f = @field(msg, field.name);
        switch (field.type) {
            i32, u32 => {
                rb.putT(field.type, f);
            },
            []const u8 => {
                rb.putT(u32, @intCast(f.len + 1));
                rb.put(f.data);
                for (0..(aligned(f.len + 1) - f.len)) |_| {
                    rb.put("\x00");
                }
            },
            way.any => {
                const str = f.interface;
                rb.putT(u32, @intCast(str.len + 1));
                rb.putT(str);
                for (0..(aligned(str.len + 1) - str.len)) |_| {
                    rb.put("\x00");
                }
                rb.putT(u32, f.version);
                rb.putT(u32, f.id);
            },
            inline else => |X| switch (comptime meta.getKind(X)) {
                .interface => rb.putT(u32, f.id),
                .@"enum" => rb.putT(X, f),
                else => @compileError(@typeName(X) ++ " is not Enum, nor Interface"),
            },
        }
    }
    const conn = Connection.init(socket);
    try conn.send(.{ .msg = rb, .ctrl = "" });
}

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

pub fn main(init: std.process.Init) !void {
    const soc = try init_display(init);
    const alloc = init.arena.allocator();

    var env = Env.init();
    const display = env.new(way.wayland.wl_display);
    const registry = env.new(way.wayland.wl_registry);
    const wl_callback = env.new(way.wayland.wl_callback);
    try send(soc, display, way.wayland.wl_display.Request.get_registry{ .registry = registry });
    try send(soc, display, way.wayland.wl_display.Request.sync{ .callback = wl_callback });
    try std.Io.sleep(init.io, .fromMilliseconds(200), .real); // too fast otherwise
    // const rs = try read(alloc, &env, soc);
    var con = Connection.init(soc);
    var rs = MsgIt.init((try con.recv()).?);
    while (rs.next(alloc, &env)) |r| switch (r.type_id.val) {
        meta.index(.event, way.wayland.wl_registry.Event.global).?.val => {
            const x: *way.wayland.wl_registry.Event.global = @ptrCast(@alignCast(r.bytes));
            std.debug.print("global name: {} version: {} interface: {s}\n", .{ x.name, x.version, x.interface });
        },
        meta.lists.events.types.len...std.math.maxInt(usize) => unreachable,
        inline else => |i| std.debug.print("Ignored Msg {s}\n", .{@typeName(meta.lists.events.types[i])}),
    };
}
