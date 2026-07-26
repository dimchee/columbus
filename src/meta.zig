const std = @import("std");
const way = @import("wayland.zig");

pub const TypeId = *const struct { _: u8 };
pub inline fn typeId(comptime T: type) TypeId {
    return &struct {
        comptime {
            _ = T;
        }
        var id: @typeInfo(TypeId).pointer.child = undefined;
    }.id;
}
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
pub fn mapTypeIndex(field_types: []const type) TypeMap(usize, field_types) {
    return x: {
        var sol: TypeMap(usize, field_types) = undefined;
        for (field_types, 0..) |ft, i| @field(sol, @typeName(ft)) = i;
        break :x sol;
    };
}
const lists = struct {
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
    const interfaces = x: {
        const protocol = @typeInfo(way.wayland);
        const len = protocol.@"struct".decls.len;
        var sol: [len]type = undefined;
        for (protocol.@"struct".decls, 0..) |interface, i|
            sol[i] = @field(way.wayland, interface.name);
        break :x sol;
    };
    const enums = get("Enum");
    const events = get("Event");
    const requests = get("Request");
};
const maps = struct {
    const interface = mapTypeIndex(&lists.interfaces);
    const @"enum" = mapTypeIndex(lists.enums.types);
    const event = mapTypeIndex(lists.events.types);
    const request = mapTypeIndex(lists.requests.types);
};
pub fn index(k: Kind, T: type) ?usize {
    if (!@inComptime()) @compileError("meta available at comptime only!");
    return getVal(T, usize, @field(maps, @tagName(k)));
}
pub fn is(k: Kind, T: type) bool {
    return index(k, T) != null;
}
pub fn opcode(T: type) comptime_int {
    if (is(.event, T)) return lists.events.opCodes[index(.event, T).?];
    if (is(.request, T)) return lists.requests.opCodes[index(.request, T).?];
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
