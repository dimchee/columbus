const std = @import("std");

pub const any = struct { interface: str, version: u32, id: u32 };
pub const fd = struct { fd: i32 };
pub const str = struct {
    main: []const u8,
    wrap: []const u8,
    pub inline fn len(self: @This()) usize {
        return self.main.len + self.wrap.len;
    }
    pub inline fn fromStr(x: []const u8) @This() {
        return .{ .main = x, .wrap = "" };
    }
    pub fn format(self: @This(), w: *std.Io.Writer) !void {
        try w.writeAll(self.main);
        try w.writeAll(self.wrap);
    }
    pub fn eql(self: @This(), x: []const u8) bool {
        const ml = self.main.len;
        for (0..self.main.len) |i| if (self.main[i] != x[i]) return false;
        for (0..self.wrap.len) |i| if (self.main[i] != x[ml + i]) return false;
        return true;
    }
};
pub const array = struct { data: str };
