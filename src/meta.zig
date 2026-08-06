const std = @import("std");
const way = @import("wayland.zig");

const Kind = enum { interface, request, event, @"enum" };
pub fn TypeMap(Val: type, types: []const type) type {
    const field_names = y: {
        var names: [types.len][]const u8 = undefined;
        for (types, 0..) |ft, i| names[i] = @typeName(ft);
        break :y names;
    };
    const field_attrs = [1]std.builtin.Type.StructField.Attributes{.{}} ** types.len;
    return @Struct(.auto, null, &field_names, &[1]type{Val} ** types.len, &field_attrs);
}
pub fn getVal(Key: type, Val: type, map: anytype) ?Val {
    return if (@hasField(@TypeOf(map), @typeName(Key))) @field(map, @typeName(Key)) else null;
}
pub fn Index(_: Kind) type {
    return packed struct { val: usize };
}
pub fn mapTypeIndex(k: Kind, field_types: []const type) TypeMap(Index(k), field_types) {
    var sol: TypeMap(Index(k), field_types) = undefined;
    for (field_types, 0..) |ft, i| @field(sol, @typeName(ft)) = .{ .val = i };
    return sol;
}
pub const lists = struct {
    fn get(name: []const u8) struct { types: []const type, opCodes: []const usize } {
        const len = x: {
            var len = 0;
            for (interfaces) |I|
                len += @typeInfo(@field(I, name)).@"struct".decls.len;
            break :x len;
        };
        const sol = x: {
            var sol: struct { ts: [len]type, cs: [len]usize } = undefined;
            var cur = 0;
            for (interfaces) |I| {
                for (@typeInfo(@field(I, name)).@"struct".decls, 0..) |e, i| {
                    sol.ts[cur + i] = @field(@field(I, name), e.name);
                    sol.cs[cur + i] = i;
                }
                cur += @typeInfo(@field(I, name)).@"struct".decls.len;
            }
            break :x sol;
        };
        return .{ .types = &sol.ts, .opCodes = &sol.cs };
    }
    pub const interfaces = x: {
        const len = y: {
            var len = 0;
            for (@typeInfo(way.protocol).@"struct".decls) |p| {
                const protocol = @typeInfo(@field(way.protocol, p.name));
                len += protocol.@"struct".decls.len;
            }
            break :y len;
        };
        var sol: [len]type = undefined;
        var cur = 0;
        for (@typeInfo(way.protocol).@"struct".decls) |p| {
            const protocol = @field(way.protocol, p.name);
            for (@typeInfo(protocol).@"struct".decls, 0..) |interface, i|
                sol[cur + i] = @field(protocol, interface.name);
            cur += @typeInfo(protocol).@"struct".decls.len;
        }
        break :x sol;
    };
    pub const enums = get("Enum");
    pub const events = get("Event");
    pub const requests = get("Request");
};
const maps = struct {
    const interface = mapTypeIndex(.interface, &lists.interfaces);
    const @"enum" = mapTypeIndex(.@"enum", lists.enums.types);
    const event = mapTypeIndex(.event, lists.events.types);
    const request = mapTypeIndex(.request, lists.requests.types);
};
pub fn index(k: Kind, T: type) ?Index(k) {
    if (!@inComptime()) @compileError("meta available at comptime only!");
    return getVal(T, Index(k), @field(maps, @tagName(k)));
}
pub inline fn is(k: Kind, T: type) bool {
    return index(k, T) != null;
}
pub fn getKind(T: type) Kind {
    for (@typeInfo(Kind).@"enum".fields) |f| {
        const k = @field(Kind, f.name);
        if (is(k, T)) return k;
    }
    @compileError(@typeName(T) ++ " doesn't have Kind");
}
pub fn opcode(T: type) comptime_int {
    if (is(.event, T)) return lists.events.opCodes[index(.event, T).?.val];
    if (is(.request, T)) return lists.requests.opCodes[index(.request, T).?.val];
    @compileError("Opcode is available for events and requests only!");
}

// comptime {
//     @setEvalBranchQuota(5300);
//     // @compileLog(events.types.len); 58
//     // @compileLog(requests.types.len); 65
//     for (lists.events.types) |e|
//         if (e.Opcode != opcode(e)) @compileError("Wrong Opcode");
//     for (lists.requests.types) |e|
//         if (e.Opcode != opcode(e)) @compileError("Wrong Opcode");
//     for (lists.events.types) |e|
//         if (e.Opcode != opcode(e)) @compileError("Wrong Opcode");
//     for (lists.requests.types) |e|
//         if (e.Opcode != opcode(e)) @compileError("Wrong Opcode");
//     for (lists.events.types) |e|
//         if (e.Opcode != opcode(e)) @compileError("Wrong Opcode");
//     for (lists.requests.types) |e|
//         if (e.Opcode != opcode(e)) @compileError("Wrong Opcode");
//     for (lists.events.types) |e|
//         if (e.Opcode != opcode(e)) @compileError("Wrong Opcode");
//     for (lists.requests.types) |e|
//         if (e.Opcode != opcode(e)) @compileError("Wrong Opcode");
//     for (lists.events.types) |e|
//         if (e.Opcode != opcode(e)) @compileError("Wrong Opcode");
//     for (lists.requests.types) |e|
//         if (e.Opcode != opcode(e)) @compileError("Wrong Opcode");
// }
