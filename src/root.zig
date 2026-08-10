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

const wl_registry = way.protocol.wayland.wl_registry;
pub const RegistryBinder = struct {
    con: *Connection,
    registry: wl_registry,
    pub fn init(con: *Connection, registry: wl_registry) @This() {
        return .{ .con = con, .registry = registry };
    }
    pub fn bind(self: *@This(), x: wl_registry.Event.global, name: []const u8, version: u32, id: u32) void {
        if (x.interface.eql(name)) {
            self.con.io.sender.push(self.registry, wl_registry.Request.bind{
                .name = x.name,
                .id = way.types.any{
                    .interface = way.types.str.fromStr(name),
                    .version = version,
                    .id = id,
                },
            });
            self.con.send();
        }
    }
};

const ItFn = fn (T: type, x: anytype, args: anytype) callconv(.@"inline") bool;
const OnBlockFn = fn (std.Io) callconv(.@"inline") bool;
pub inline fn alwaysFalse(_: std.Io) bool {
    return false;
}
pub fn wait_for(dur: std.Io.Duration) OnBlockFn {
    return struct {
        inline fn f(io: std.Io) bool {
            std.Io.sleep(io, dur, .real) catch return false;
            return true;
        }
    }.f;
}
pub fn loop(io: std.Io, con: *Connection, env: *Env, args: anytype, runs: anytype, on_block: fn (io: std.Io) callconv(.@"inline") bool) !void {
    loop: while (true) {
        con.recv() catch if (!on_block(io)) break :loop;
        while (con.io.recver.popHeader(&env.env)) |t_id| switch (t_id.val) {
            meta.lists.events.types.len...std.math.maxInt(usize) => unreachable,
            inline else => |i| {
                const T = meta.lists.events.types[i];
                const x = con.io.recver.popOp(T);
                inline for (runs) |run| {
                    // if (@TypeOf(run) != ItFn) @compileError(@typeName(@TypeOf(run)) ++ " run have to be of type " ++ @typeName(ItFn));
                    if (!run(T, x, args)) break :loop;
                }
            },
        };
    }
}
