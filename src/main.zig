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

// This connection has ring buffer for recv and for send. Recv fills ring buffer, send empties ring buffer. You should yorself do the rest
// TODO multiple msgs `send` and `recv`
const Connection = struct {
    // std.Io.Writer.fixed
    const Buf = struct { msg: [2048]u8, ctrl: [1024]u8 };
    const Msg = struct { msg: []u8, ctrl: []u8 };
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
            .iov = &[_]std.posix.iovec_const{.{ .base = msg.msg.ptr, .len = msg.msg.len }},
            .iovlen = 1,
            .control = msg.ctrl.ptr,
            .controllen = msg.ctrl.len,
            .flags = 0,
        }, 0) < msg.msg.len) @panic("Impossible");
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
        return Msg{ .msg = self.buf.recv.msg[0..len], .ctrl = self.buf.recv.ctrl[0..] };
    }
};

const MsgIt = struct {
    msg: []u8,
    ctrl: []u8,
    fn init(msg: Connection.Msg) @This() {
        return .{ .msg = msg.msg, .ctrl = msg.ctrl };
    }
    fn get(T: type, bytes: *[]u8) T {
        const sol: T = @bitCast(bytes.*[0..@sizeOf(T)].*);
        bytes.* = bytes.*[@sizeOf(T)..];
        return sol;
    }
    fn readOp(self: *@This(), Op: type) Op {
        var op: Op = undefined;
        inline for (@typeInfo(Op).@"struct".fields) |field| {
            switch (field.type) {
                i32, u32 => @field(op, field.name) = get(field.type, &self.msg),
                []const u8 => {
                    const len = get(u32, &self.msg);
                    @field(op, field.name) = self.msg[0 .. len - 1];
                    self.msg = self.msg[std.mem.alignForward(u16, @intCast(len), @sizeOf(u32))..];
                },
                // way.array => {
                //     const len = mem.self.msg.readT(u32);
                //     @field(op, field.name) = .{ .data = mem.self.msg.read(len) };
                //     _ = mem.self.msg.read(Mem.aligned(len) - len);
                // },
                way.fd => {
                    self.msg = self.msg[@sizeOf(u64) + @sizeOf(i32) + @sizeOf(i32) ..]; // _, std.posix.SOL.SOCKET, 0x01
                    @field(op, field.name) = .{ .fd = get(i32, &self.ctrl) };
                },
                inline else => |X| if (comptime meta.is(.interface, X)) {
                    @panic("ToDoInterface");
                } else if (comptime meta.is(.@"enum", X)) {
                    @panic("ToDoEnum");
                    // @field(op, field.name) = get(field.type, &self.msg);
                } else @compileError(@typeName(X) ++ " is not readable"),
            }
        }
        return op;
    }
    const Read = struct { type_id: meta.Index(.event), bytes: []u8 };
    pub fn next(self: *@This(), alloc: std.mem.Allocator, env: *Env) ?Read {
        if (self.msg.len == 0) return null; // TODO hack
        if (self.msg.len < @sizeOf(Header)) @panic("Impossible");
        const header = get(Header, &self.msg);
        if (self.msg.len + @sizeOf(Header) < header.size) @panic("Impossible");
        switch (env.env[header.object_id].val) {
            meta.lists.interfaces.len...std.math.maxInt(usize) => unreachable,
            inline else => |ind| {
                const I = meta.lists.interfaces[ind];
                const ops = @typeInfo(I.Event).@"struct".decls;
                if (ops.len != 0) {
                    switch (header.opcode) {
                        ops.len...std.math.maxInt(@TypeOf(header.opcode)) => unreachable,
                        inline else => |op_id| {
                            const Op = @field(I.Event, ops[op_id].name);
                            const op = alloc.create(Op) catch @panic("Couldn't allocate");
                            op.* = self.readOp(Op);
                            return Read{ .bytes = @ptrCast(op), .type_id = comptime meta.index(.event, Op).? };
                        },
                    }
                } else unreachable;
            },
        }
    }
};
const Header = extern struct { object_id: u32, opcode: u16, size: u16 };
const Len = struct { ctrl: u16, msg: u16 };
// TODO remove struct, put `push` in Msg
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
// TODO Batch sendmsg
pub fn send(socket: std.posix.socket_t, alloc: std.mem.Allocator, sender: anytype, msg: anytype) !void {
    const len = x: {
        var len = Len{ .ctrl = 0, .msg = @sizeOf(Header) };
        inline for (@typeInfo(@TypeOf(msg)).@"struct".fields) |field| {
            const f = @field(msg, field.name);
            switch (field.type) { // TODO solve magic numbers
                i32, u32 => len.msg += @sizeOf(i32),
                []const u8 => len.msg += 4 + Mem.aligned(f.len + 1),
                way.fd => len.ctrl += 20, // TODO why?
                way.any => len.msg += 4 + Mem.aligned(f.interface.len + 1) + 4 + 4,
                inline else => |X| if (comptime meta.is(.interface, X) or meta.is(.@"enum", X)) {
                    len.msg += @sizeOf(X);
                } else @compileError(@typeName(X) ++ " is not Enum, nor Interface"),
            }
        }
        break :x len;
    };
    // var buf: struct { msg: [2048]u8, ctrl: [1024]u8 } = undefined;
    // const ws = .{ .msg = std.Io.Writer.fixed(&buf.msg), .ctrl = std.Io.Writer.fixed(&buf.ctrl) };
    const data = Connection.Msg{ .msg = try alloc.alloc(u8, len.msg), .ctrl = try alloc.alloc(u8, len.ctrl) };
    var mem = .{ .msg = Mem{ .mem = data.msg }, .ctrl = Mem{ .mem = data.ctrl } };
    mem.msg.push(Header, .{
        .object_id = sender.id,
        .opcode = meta.opcode(@TypeOf(msg)),
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
            inline else => |X| if (comptime meta.is(.interface, X))
                mem.msg.push(u32, f.id)
            else if (comptime meta.is_enum(X))
                mem.msg.push(X, f)
            else
                @compileError(@typeName(X) ++ " is not Enum, nor Interface"),
        }
        std.debug.assert(mem.msg.mem.len == 0);
        std.debug.assert(mem.ctrl.mem.len == 0);
    }
    const conn = Connection.init(socket);
    try conn.send(data);
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
    try send(soc, alloc, display, way.wayland.wl_display.Request.get_registry{ .registry = registry });
    try send(soc, alloc, display, way.wayland.wl_display.Request.sync{ .callback = wl_callback });
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
