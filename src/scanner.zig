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
    fn begin(self: *@This(), what: []const u8, name: []const u8) !void {
        try self.print("pub const {s} = {s} {{", .{ mod(name), what });
        self.indent += 4;
    }
    fn end(self: *@This()) !void {
        self.indent -= 4;
        try self.print("}};", .{});
    }
};

const Normalizer = struct {
    alloc: std.mem.Allocator,
    fn init(alloc: std.mem.Allocator) @This() {
        return .{ .alloc = alloc };
    }
    fn get(self: @This(), str: []const u8) ![]const u8 {
        return switch (str[0]) {
            '0'...'9' => std.fmt.allocPrint(self.alloc, "@\"{s}\"", .{str}),
            else => str,
        };
    }
    fn getType(self: @This(), x: Interface.Msg.Arg) ![]const u8 {
        return switch (x.type) {
            .array => "types.array", // Should be wrapped?
            .fixed => "i32", // Signed 24.8 decimal numbers
            .fd => "types.fd", //"std.posix.fd_t",
            .int => "i32",
            // maybe use wl_registry.global as any?
            .new_id => x.interface orelse "types.any",
            .object => "u32", // id of object
            .string => "types.str",
            .uint => if (x.@"enum") |e| sol: {
                var it = std.mem.splitBackwardsScalar(u8, e, '.');
                const name = it.next().?;
                break :sol try if (it.next()) |i|
                    std.fmt.allocPrint(self.alloc, "{s}.Enum.{s}", .{ i, name })
                else
                    std.fmt.allocPrint(self.alloc, "Enum.{s}", .{name});
                // break :sol try std.fmt.allocPrint(alloc, "{s}.{s}.{s}", .{ mI orelse "Interface", "Enum", name });
            } else "u32",
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const nz = Normalizer.init(alloc);

    const parsed = try Parsed.init(init, &[_][]const u8{
        "spec/wayland.json",
        "spec/xdg-shell.json",
        // "spec/linux-dmabuf.json",
    });
    defer parsed.deinit();
    var w = try Wrapper.init(init.io, "src/wayland.zig");
    defer w.deinit();
    try w.print("pub const types = @import(\"types.zig\");", .{});
    try w.begin("struct", "protocol");
    for (parsed.protocols) |protocol| {
        try w.begin("struct", protocol.name);
        for (protocol.interface) |interface| {
            try w.begin("struct", interface.name);
            try w.print("id: u32,", .{});
            try w.begin("struct", "Enum");
            for (interface.@"enum".data) |e| {
                try w.begin("enum(u32)", e.name);
                for (e.entry.data) |a|
                    try w.print("{s} = {s},", .{ try nz.get(a.name), a.value });

                try w.print("_, // NonExaustive, see  `wl_seat.Enum.capability`", .{}); // ToDo some are exaustive
                try w.end();
            }
            try w.end();
            try w.begin("struct", "Event");
            for (interface.event.data) |e| {
                try w.begin("struct", e.name);
                for (e.arg.data) |a|
                    try w.print("{s}: {s},", .{ a.name, try nz.getType(a) });
                try w.end();
            }
            try w.end();
            try w.begin("struct", "Request");
            for (interface.request.data) |e| {
                try w.begin("struct", e.name);
                for (e.arg.data) |a|
                    try w.print("{s}: {s},", .{ a.name, try nz.getType(a) });
                try w.end();
            }
            try w.end();
            try w.end();
        }
        try w.end();
    }
    try w.end();
}
