pub fn RingBuffer(comptime CAPACITY: usize) type {
    return struct {
        data: [CAPACITY]u8,
        head: usize,
        len: usize,
        pub fn init() @This() {
            return .{ .data = undefined, .head = 0, .len = 0 };
        }
        pub inline fn tail(self: *const @This()) usize {
            return @min(self.head + self.len -% self.data.len, self.head + self.len);
        }
        const View = struct { main: []u8, wrap: []u8 };
        fn view(self: *@This(), head: usize, len: usize) View {
            return if (head + len < self.data.len)
                .{ .main = self.data[head .. head + len], .wrap = "" }
            else
                .{ .main = self.data[head..self.data.len], .wrap = self.data[0 .. head + len - self.data.len] };
        }
        pub fn used(self: *@This()) View {
            return self.view(self.head, self.len);
        }
        pub fn free(self: *@This()) View {
            return self.view(self.tail(), self.data.len - self.len);
        }
        pub fn put(self: *@This(), bytes: []const u8) void {
            if (self.data.len < self.len + bytes.len) @panic("Can't put - RingBuffer too long");
            const str = self.view(self.tail(), bytes.len);
            @memcpy(str.main, bytes.ptr);
            if (0 < str.wrap.len) @memcpy(str.wrap, bytes[str.main.len..].ptr);
            self.len += bytes.len;
        }
        pub fn peek(self: *@This(), bytes: []u8) void {
            if (self.len < bytes.len) @panic("can't get - ringbuffer too short");
            const str = self.view(self.head, bytes.len);
            @memcpy(bytes.ptr, str.main);
            if (0 < str.wrap.len) @memcpy(bytes[str.main.len..].ptr, str.wrap);
        }
        pub fn get(self: *@This(), bytes: []u8) void {
            self.peek(bytes);
            self.head = @min(self.head + bytes.len -% self.data.len, self.head + bytes.len);
            self.len -= bytes.len;
        }
        fn DeferedPut(T: type) type {
            return struct {
                view: View,
                pub inline fn put(self: @This(), x: T) void {
                    const bytes: []const u8 = @ptrCast(&x);
                    @memcpy(self.view.main, bytes.ptr);
                    if (0 < self.view.wrap.len) @memcpy(self.view.wrap, bytes[self.view.main.len..].ptr);
                }
            };
        }
        pub fn putTDefered(self: *@This(), T: type) DeferedPut(T) {
            if (self.data.len < self.len + @sizeOf(T)) @panic("Can't put - RingBuffer too long");
            const v = self.view(self.tail(), @sizeOf(T));
            self.len += @sizeOf(T);
            return .{ .view = v };
        }
        pub fn putT(self: *@This(), T: type, x: T) void {
            self.put(@ptrCast(&x));
        }
        pub fn peekT(self: *@This(), T: type) T {
            var x: T = undefined;
            self.peek(@ptrCast(&x));
            return x;
        }
        pub fn getT(self: *@This(), T: type) T {
            var x: T = undefined;
            self.get(@ptrCast(&x));
            return x;
        }
        pub fn putN(self: *@This(), n: usize) void {
            if (self.data.len < self.len + n) @panic("Can't put - RingBuffer too long");
            self.len += n;
        }
        pub fn getN(self: *@This(), n: usize) View {
            if (self.len < n) @panic("Can't get - RingBuffer too short");
            const sol = self.view(self.head, n);
            self.len -= n;
            self.head = @min(self.head + n -% self.data.len, self.head + n);
            return .{ .main = sol.main, .wrap = sol.wrap };
        }
    };
}
