const std = @import("std");

pub const any = struct { interface: []const u8, version: u32, id: u32 };
pub const fd = struct { fd: i32 };
pub const str = struct {
    main: []const u8,
    wrap: []const u8,
    pub inline fn len(self: @This()) usize {
        return self.main.len + self.wrap.len;
    }
    pub fn format(self: @This(), w: *std.Io.Writer) !void {
        try w.writeAll(self.main);
        try w.writeAll(self.wrap);
    }
};
pub const array = struct { data: str };
