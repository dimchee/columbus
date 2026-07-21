const std = @import("std");

pub fn OptionalList(comptime T: type) type {
    return union(enum) {
        const default: @This() = .{ .data = &.{} };
        data: []T,
        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, opts: std.json.ParseOptions) !@This() {
            return switch (try source.peekNextTokenType()) {
                .null => .default,
                .array_begin => .{ .data = try std.json.innerParse([]T, allocator, source, opts) },
                else => x: {
                    var arr = try allocator.alloc(T, 1);
                    arr[0] = try std.json.innerParse(T, allocator, source, opts);
                    break :x .{ .data = arr };
                },
            };
        }
    };
}
pub const Root = struct {
    protocol: Protocol,
};
pub const Protocol = struct {
    name: []const u8,
    copyright: []const u8,
    interface: []Interface,
};
// ToDo App(.client) so you can only send requests, and recv events
pub const Interface = struct {
    pub const Description = struct {
        summary: []const u8,
        text: ?[]const u8 = null,
    };
    pub const Enum = struct {
        pub const Entry = struct {
            name: []const u8,
            summary: ?[]const u8 = null,
            value: []const u8, // ToDo parse integers
        };
        name: []const u8,
        description: ?Description = null,
        bitfield: []const u8 = "false", // ToDo use bitfields
        entry: OptionalList(Entry),
    };
    const Msg = struct {
        const Arg = struct {
            const Type = enum { array, fixed, fd, int, new_id, object, string, uint };
            name: []const u8,
            summary: ?[]const u8 = null,
            type: @This().Type,
            interface: ?[]const u8 = null,
            @"enum": ?[]const u8 = null,
        };
        const Type = enum { destructor };
        name: []const u8,
        // description: Description,
        arg: OptionalList(Arg) = .default,
        type: ?Type = null,
    };
    name: []const u8,
    version: []const u8,
    // description: ?Description = null,
    @"enum": OptionalList(Enum) = .default,
    event: OptionalList(Msg) = .default,
    request: OptionalList(Msg) = .default,
};

pub const Parsed = struct {
    parsed: []std.json.Parsed(Root),
    protocols: []Protocol,
    pub fn init(pinit: std.process.Init, paths: []const []const u8) !@This() {
        const alloc = pinit.arena.allocator();
        const parsed = try alloc.alloc(std.json.Parsed(Root), paths.len);
        const protocols = try alloc.alloc(Protocol, paths.len);
        for (paths, parsed, protocols) |path, *x, *p| {
            const str = try std.Io.Dir.cwd().readFileAlloc(pinit.io, path, alloc, std.Io.Limit.unlimited);
            x.* = try std.json.parseFromSlice(Root, alloc, str, .{ .ignore_unknown_fields = true });
            p.* = x.value.protocol;
        }
        return .{ .parsed = parsed, .protocols = protocols };
    }
    pub fn deinit(self: @This()) void {
        for (self.parsed) |p| p.deinit();
    }
};

const Wrapper = struct {
    indent: usize,
    out: std.Io.File.Writer,
    file: std.Io.File,
    io: std.Io,
    fn init(io: std.Io, fileName: []const u8) !@This() {
        var sol: @This() = undefined;
        sol.io = io;
        sol.file = try std.Io.Dir.cwd().createFile(io, fileName, .{});
        sol.out = sol.file.writer(io, &.{});
        sol.indent = 0;
        return sol;
    }
    fn deinit(self: *@This()) void {
        self.out.flush() catch return;
        self.file.close(self.io);
    }
    fn mod(str: []const u8) []const u8 {
        return if (std.mem.eql(u8, str, "error")) "Error" else str;
    }
    fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
        for (0..self.indent) |_| try self.out.interface.print(" ", .{});
        try self.out.interface.print(fmt, args);
        try self.out.interface.print("\n", .{});
    }
    fn begin(self: *@This(), name: []const u8) !void {
        try self.print("pub const {s} = struct {{", .{mod(name)});
        self.indent += 4;
    }
    fn addConst(self: *@This(), name: []const u8, value: []const u8) !void {
        try self.print("pub const {s} = {s};", .{ name, mod(value) });
    }
    fn end(self: *@This()) !void {
        self.indent -= 4;
        try self.print("}};", .{});
    }
};

fn getPrefix(x: Interface.Msg.Arg) []const u8 {
    return switch (x.type) {
        .new_id => if (x.interface) |_| "Interface.Protocol." else "",
        .uint => if (x.@"enum") |_| "Interface.Enum." else "",
        else => "",
    };
}
fn getType(x: Interface.Msg.Arg) []const u8 {
    return switch (x.type) {
        .array => "[]const u8", // Should be wrapped?
        .fixed => "i32", // Signed 24.8 decimal numbers
        .fd => "fd", //"std.posix.fd_t",
        .int => "i32",
        // pub const any = struct { interface: []const u8, version: u32, id: u32 };
        // maybe use wl_registry.global?
        .new_id => x.interface orelse "any",
        .object => "u32", // id of object
        .string => "[]const u8",
        .uint => x.@"enum" orelse "u32",
    };
}

pub fn main(init: std.process.Init) !void {
    const parsed = try Parsed.init(init, &[_][]const u8{"spec/wayland.json"});
    defer parsed.deinit();
    var w = try Wrapper.init(init.io, "src/wayland.zig");
    defer w.deinit();
    try w.print("pub const any = struct {{ interface: []const u8, version: u32, id: u32 }};", .{});
    try w.print("pub const fd = struct {{ fd: i32 }};", .{});
    for (parsed.protocols) |protocol| {
        try w.begin(protocol.name);
        for (protocol.interface) |interface| {
            try w.begin(interface.name);
            try w.addConst("Protocol", protocol.name);
            try w.print("id: u32,", .{});
            try w.begin("Enum");
            for (interface.@"enum".data) |e| {
                try w.begin(e.name);
                try w.addConst("Interface", interface.name);
                try w.end();
            }
            try w.end();
            try w.begin("Event");
            for (interface.event.data, 0..) |e, opcode| {
                try w.begin(e.name);
                try w.addConst("Interface", interface.name);
                try w.print("pub const Opcode = {};", .{opcode});
                for (e.arg.data) |a|
                    try w.print("{s}: {s}{s},", .{ a.name, getPrefix(a), getType(a) });
                try w.end();
            }
            try w.end();
            try w.begin("Request");
            for (interface.request.data, 0..) |e, opcode| {
                try w.begin(e.name);
                try w.addConst("Interface", interface.name);
                try w.print("pub const Opcode = {};", .{opcode});
                for (e.arg.data) |a|
                    try w.print("{s}: {s}{s},", .{ a.name, getPrefix(a), getType(a) });
                try w.end();
            }
            try w.end();
            try w.end();
        }
        try w.end();
    }
}
