//! Render engine: AST + JSON data -> Textile bytes.
//!
//! Every filter emits Textile (README.md mapping table), never Markdown.
//! Missing variables render as empty text and are falsy in conditions
//! (knap.md/logic truthiness list).

const std = @import("std");
const diag = @import("diag.zig");
const parse = @import("parse.zig");
const filters = @import("filters.zig");

pub const Diag = diag.Diag;
pub const Error = error{ Render, OutOfMemory };

pub const max_list_depth: usize = 3;

/// Renders the template into `out` (caller-owned buffer). On error.Render the
/// diagnostic is returned in `*err_out`; `out` may hold partial bytes and must
/// then be discarded by the caller (the CLI only writes it on full success).
pub fn render(
    gpa: std.mem.Allocator,
    template: *const parse.Template,
    data: std.json.Value,
    out: *std.ArrayList(u8),
    err_out: *?Diag,
) Error!void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var eng = Engine{
        .gpa = gpa,
        .arena = arena.allocator(),
        .src = template.src,
        .data = data,
        .out = out,
        .err_out = err_out,
    };
    return eng.renderNodes(template.nodes, null);
}

const Env = struct {
    parent: ?*const Env,
    name: []const u8,
    val: std.json.Value,
};

const Engine = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    src: []const u8,
    data: std.json.Value,
    out: *std.ArrayList(u8),
    err_out: *?Diag,

    fn failAt(self: *Engine, kind: diag.Kind, pos: usize, comptime fmt: []const u8, args: anytype) Error {
        if (self.err_out.* == null) {
            const lc = diag.lineCol(self.src, pos);
            // Diagnostic messages are allocated from the caller's allocator so
            // they remain valid after the engine's scratch arena is freed.
            const msg = std.fmt.allocPrint(self.gpa, fmt, args) catch return error.OutOfMemory;
            self.err_out.* = .{ .kind = kind, .line = lc.line, .col = lc.col, .msg = msg };
        }
        return error.Render;
    }

    fn renderNodes(self: *Engine, nodes: []const parse.Node, env: ?*const Env) Error!void {
        for (nodes) |node| {
            switch (node) {
                .text => |t| try self.out.appendSlice(self.gpa, t),
                .output => |o| {
                    var v = try self.evalExpr(o.expr, env);
                    v = try self.applyFilters(v, o.filters);
                    try self.appendValueText(v);
                },
                .if_ => |iff| {
                    for (iff.branches) |branch| {
                        const take = if (branch.cond) |cond|
                            truthy(try self.evalExpr(cond, env))
                        else
                            true;
                        if (take) {
                            try self.renderNodes(branch.body, env);
                            break;
                        }
                    }
                },
                .for_ => |f| {
                    const list = try self.evalExpr(f.expr, env);
                    if (list != .array) {
                        return self.failAt(
                            .render,
                            f.pos,
                            "for-loop expects an array to iterate, but got a {s}",
                            .{typeName(list)},
                        );
                    }
                    const items = list.array.items;
                    for (items, 0..) |item, i| {
                        var loop_obj = std.json.ObjectMap.empty;
                        try loop_obj.put(self.arena, "index", .{ .integer = @intCast(i + 1) });
                        try loop_obj.put(self.arena, "index0", .{ .integer = @intCast(i) });
                        try loop_obj.put(self.arena, "first", .{ .bool = i == 0 });
                        try loop_obj.put(self.arena, "last", .{ .bool = i + 1 == items.len });
                        try loop_obj.put(self.arena, "length", .{ .integer = @intCast(items.len) });

                        const item_frame = Env{ .parent = env, .name = f.iter, .val = item };
                        const loop_frame = Env{ .parent = &item_frame, .name = "loop", .val = .{ .object = loop_obj } };
                        try self.renderNodes(f.body, &loop_frame);
                    }
                },
            }
        }
    }

    // ---- expressions --------------------------------------------------------

    fn evalExpr(self: *Engine, expr: parse.Expr, env: ?*const Env) Error!std.json.Value {
        return switch (expr) {
            .literal => |lit| switch (lit) {
                .string => |s| .{ .string = s },
                .int => |i| .{ .integer = i },
                .float => |f| .{ .float = f },
                .boolean => |b| .{ .bool = b },
                .nul => .null,
            },
            .path => |p| self.evalPath(p, env),
            .not => |operand| .{ .bool = !truthy(try self.evalExpr(operand.*, env)) },
            .binary => |b| try self.evalBinary(b, env),
        };
    }

    fn evalPath(self: *Engine, path: parse.Path, env: ?*const Env) Error!std.json.Value {
        var v: std.json.Value = blk: {
            var e = env;
            while (e) |frame| : (e = frame.parent) {
                if (std.mem.eql(u8, frame.name, path.root)) break :blk frame.val;
            }
            break :blk objectGet(self.data, path.root) orelse .null;
        };
        for (path.segments) |seg| {
            v = switch (seg) {
                .dot => |name| objectGet(v, name) orelse .null,
                .key => |key| objectGet(v, key) orelse .null,
                .index => |idx| if (v == .array and idx < v.array.items.len)
                    v.array.items[idx]
                else
                    .null,
            };
        }
        return v;
    }

    fn evalBinary(self: *Engine, b: anytype, env: ?*const Env) Error!std.json.Value {
        switch (b.op) {
            .and_ => {
                if (!truthy(try self.evalExpr(b.lhs.*, env))) return .{ .bool = false };
                return .{ .bool = truthy(try self.evalExpr(b.rhs.*, env)) };
            },
            .or_ => {
                if (truthy(try self.evalExpr(b.lhs.*, env))) return .{ .bool = true };
                return .{ .bool = truthy(try self.evalExpr(b.rhs.*, env)) };
            },
            .eq => return .{ .bool = deepEqual(try self.evalExpr(b.lhs.*, env), try self.evalExpr(b.rhs.*, env)) },
            .ne => return .{ .bool = !deepEqual(try self.evalExpr(b.lhs.*, env), try self.evalExpr(b.rhs.*, env)) },
            .lt, .le, .gt, .ge => {
                const l = try self.evalExpr(b.lhs.*, env);
                const r = try self.evalExpr(b.rhs.*, env);
                const ord = compare(l, r) orelse return .{ .bool = false };
                return .{ .bool = switch (b.op) {
                    .lt => ord == .lt,
                    .le => ord != .gt,
                    .gt => ord == .gt,
                    .ge => ord != .lt,
                    else => unreachable,
                } };
            },
            .contains => {
                const l = try self.evalExpr(b.lhs.*, env);
                const r = try self.evalExpr(b.rhs.*, env);
                if (l == .string and r == .string) {
                    return .{ .bool = std.mem.indexOf(u8, l.string, r.string) != null };
                }
                if (l == .array) {
                    for (l.array.items) |item| {
                        if (deepEqual(item, r)) return .{ .bool = true };
                    }
                }
                return .{ .bool = false };
            },
        }
    }

    // ---- filters (Textile emission) ------------------------------------------

    fn applyFilters(self: *Engine, input: std.json.Value, calls: []const parse.FilterCall) Error!std.json.Value {
        var v = input;
        for (calls) |call| {
            v = try self.applyFilter(v, call);
        }
        return v;
    }

    fn applyFilter(self: *Engine, input: std.json.Value, call: parse.FilterCall) Error!std.json.Value {
        const f = filters.lookup(call.name).?;
        switch (f.tag) {
            .h1, .h2, .h3, .h4, .h5, .h6 => {
                const level: u8 = switch (f.tag) {
                    .h1 => '1',
                    .h2 => '2',
                    .h3 => '3',
                    .h4 => '4',
                    .h5 => '5',
                    .h6 => '6',
                    else => unreachable,
                };
                const text = try self.scalarText(input);
                const prefix = try std.fmt.allocPrint(self.arena, "h{c}. ", .{level});
                return .{ .string = try std.mem.concat(self.arena, u8, &.{ prefix, text }) };
            },
            .bold => {
                const text = try self.singleLine(input, call, "bold");
                return .{ .string = try std.mem.concat(self.arena, u8, &.{ "*", text, "*" }) };
            },
            .italic => {
                const text = try self.singleLine(input, call, "italic");
                return .{ .string = try std.mem.concat(self.arena, u8, &.{ "_", text, "_" }) };
            },
            .code => {
                const text = try self.singleLine(input, call, "code");
                return .{ .string = try std.mem.concat(self.arena, u8, &.{ "@", text, "@" }) };
            },
            .blockquote => {
                const text = try self.scalarText(input);
                var buf: std.ArrayList(u8) = .empty;
                var it = std.mem.splitScalar(u8, text, '\n');
                var first = true;
                while (it.next()) |line| {
                    if (!first) try buf.append(self.arena, '\n');
                    first = false;
                    try buf.appendSlice(self.arena, "bq. ");
                    try buf.appendSlice(self.arena, line);
                }
                return .{ .string = try buf.toOwnedSlice(self.arena) };
            },
            .codeblock => {
                const text = try self.scalarText(input);
                var buf: std.ArrayList(u8) = .empty;
                try buf.appendSlice(self.arena, "bc. ");
                try buf.appendSlice(self.arena, text);
                return .{ .string = try buf.toOwnedSlice(self.arena) };
            },
            .link => {
                const text = try self.singleLine(input, call, "link");
                const url = switch (call.arg.?) {
                    .string => |s| s,
                    else => |other| try self.argText(other),
                };
                if (unsafeScheme(url)) |scheme| {
                    return self.failAt(
                        .render,
                        call.pos,
                        "filter 'link' refuses unsafe URL scheme \"{s}\"",
                        .{scheme},
                    );
                }
                var buf: std.ArrayList(u8) = .empty;
                try buf.append(self.arena, '"');
                try buf.appendSlice(self.arena, text);
                try buf.appendSlice(self.arena, "\":");
                try buf.appendSlice(self.arena, url);
                return .{ .string = try buf.toOwnedSlice(self.arena) };
            },
            .list, .numbered => {
                if (input != .array) {
                    return self.failAt(
                        .render,
                        call.pos,
                        "filter '{s}' expects an array, but got a {s}",
                        .{ call.name, typeName(input) },
                    );
                }
                var buf: std.ArrayList(u8) = .empty;
                try self.emitList(input.array.items, if (f.tag == .list) '*' else '#', 1, call, &buf);
                return .{ .string = try buf.toOwnedSlice(self.arena) };
            },
            .table => {
                if (input != .array) {
                    return self.failAt(
                        .render,
                        call.pos,
                        "filter 'table' expects an array, but got a {s}",
                        .{typeName(input)},
                    );
                }
                return self.emitTable(input.array.items, call);
            },
        }
    }

    fn singleLine(self: *Engine, input: std.json.Value, call: parse.FilterCall, name: []const u8) Error![]const u8 {
        const text = try self.scalarText(input);
        if (std.mem.indexOfScalar(u8, text, '\n') != null) {
            return self.failAt(.render, call.pos, "filter '{s}' expects single-line text", .{name});
        }
        return text;
    }

    /// `* item` / `# item` lines; nested arrays deepen the marker, max 3 levels.
    /// An array item produces no line of its own — only its children, one
    /// level deeper (matching the corpus: ["one",["two"]] -> "# one\n## two").
    fn emitList(
        self: *Engine,
        items: []const std.json.Value,
        marker: u8,
        depth: usize,
        call: parse.FilterCall,
        buf: *std.ArrayList(u8),
    ) Error!void {
        for (items) |item| {
            if (item == .array) {
                if (depth + 1 > max_list_depth) {
                    return self.failAt(
                        .render,
                        call.pos,
                        "filter '{s}' supports at most {d} levels of nesting",
                        .{ call.name, max_list_depth },
                    );
                }
                try self.emitList(item.array.items, marker, depth + 1, call, buf);
            } else {
                if (buf.items.len > 0) try buf.append(self.arena, '\n');
                var d: usize = 0;
                while (d < depth) : (d += 1) try buf.append(self.arena, marker);
                try buf.append(self.arena, ' ');
                try buf.appendSlice(self.arena, try self.scalarText(item));
            }
        }
    }

    fn emitTable(self: *Engine, rows: []const std.json.Value, call: parse.FilterCall) Error!std.json.Value {
        var buf: std.ArrayList(u8) = .empty;
        if (rows.len == 0) {
            return .{ .string = try buf.toOwnedSlice(self.arena) };
        }
        const header = rows[0];
        if (header != .array) {
            return self.failAt(
                .render,
                call.pos,
                "filter 'table' expects every row to be an array, but the header row is a {s}",
                .{typeName(header)},
            );
        }
        const width = header.array.items.len;

        try buf.appendSlice(self.arena, "|_. ");
        for (header.array.items, 0..) |cell, i| {
            if (i > 0) try buf.appendSlice(self.arena, "|_. ");
            try buf.appendSlice(self.arena, try self.scalarText(cell));
        }
        try buf.append(self.arena, '|');

        for (rows[1..], 1..) |row, idx| {
            if (row != .array) {
                return self.failAt(
                    .render,
                    call.pos,
                    "filter 'table' expects every row to be an array, but row {d} is a {s}",
                    .{ idx + 1, typeName(row) },
                );
            }
            const cells = row.array.items;
            if (cells.len != width) {
                return self.failAt(
                    .render,
                    call.pos,
                    "filter 'table' expects every row to have the same number of cells (row {d} has {d}, expected {d})",
                    .{ idx + 1, cells.len, width },
                );
            }
            try buf.append(self.arena, '\n');
            for (cells) |cell| {
                try buf.append(self.arena, '|');
                try buf.appendSlice(self.arena, try self.scalarText(cell));
            }
            try buf.append(self.arena, '|');
        }
        return .{ .string = try buf.toOwnedSlice(self.arena) };
    }

    // ---- value helpers --------------------------------------------------------

    /// Text form used by interpolation and as filter input: strings verbatim,
    /// scalars formatted, objects/arrays as compact JSON.
    fn scalarText(self: *Engine, v: std.json.Value) Error![]const u8 {
        return switch (v) {
            .string => |s| s,
            .null => "",
            .bool => |b| if (b) "true" else "false",
            .integer => |i| try std.fmt.allocPrint(self.arena, "{d}", .{i}),
            .float => |f| try std.fmt.allocPrint(self.arena, "{d}", .{f}),
            .number_string => |s| s,
            .array, .object => try self.jsonText(v),
        };
    }

    fn argText(self: *Engine, arg: parse.FilterArg) Error![]const u8 {
        return switch (arg) {
            .string => |s| s,
            .int => |i| try std.fmt.allocPrint(self.arena, "{d}", .{i}),
            .float => |f| try std.fmt.allocPrint(self.arena, "{d}", .{f}),
        };
    }

    /// Compact JSON serialization (objects/arrays interpolate as JSON, matching
    /// fixtures/var-json-object).
    fn jsonText(self: *Engine, v: std.json.Value) Error![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        try self.writeJson(v, &buf);
        return try buf.toOwnedSlice(self.arena);
    }

    fn writeJson(self: *Engine, v: std.json.Value, buf: *std.ArrayList(u8)) Error!void {
        switch (v) {
            .string => |s| try self.writeJsonString(s, buf),
            .null => try buf.appendSlice(self.arena, "null"),
            .bool => |b| try buf.appendSlice(self.arena, if (b) "true" else "false"),
            .integer => |i| {
                const s = try std.fmt.allocPrint(self.arena, "{d}", .{i});
                try buf.appendSlice(self.arena, s);
            },
            .float => |f| {
                const s = try std.fmt.allocPrint(self.arena, "{d}", .{f});
                try buf.appendSlice(self.arena, s);
            },
            .number_string => |s| try buf.appendSlice(self.arena, s),
            .array => |a| {
                try buf.append(self.arena, '[');
                for (a.items, 0..) |item, i| {
                    if (i > 0) try buf.append(self.arena, ',');
                    try self.writeJson(item, buf);
                }
                try buf.append(self.arena, ']');
            },
            .object => |o| {
                try buf.append(self.arena, '{');
                var it = o.iterator();
                var first = true;
                while (it.next()) |entry| {
                    if (!first) try buf.append(self.arena, ',');
                    first = false;
                    try self.writeJsonString(entry.key_ptr.*, buf);
                    try buf.append(self.arena, ':');
                    try self.writeJson(entry.value_ptr.*, buf);
                }
                try buf.append(self.arena, '}');
            },
        }
    }

    fn writeJsonString(self: *Engine, s: []const u8, buf: *std.ArrayList(u8)) Error!void {
        try buf.append(self.arena, '"');
        for (s) |ch| {
            switch (ch) {
                '"' => try buf.appendSlice(self.arena, "\\\""),
                '\\' => try buf.appendSlice(self.arena, "\\\\"),
                '\n' => try buf.appendSlice(self.arena, "\\n"),
                '\r' => try buf.appendSlice(self.arena, "\\r"),
                '\t' => try buf.appendSlice(self.arena, "\\t"),
                else => {
                    if (ch < 0x20) {
                        const esc = try std.fmt.allocPrint(self.arena, "\\u{x:0>4}", .{ch});
                        try buf.appendSlice(self.arena, esc);
                    } else {
                        try buf.append(self.arena, ch);
                    }
                },
            }
        }
        try buf.append(self.arena, '"');
    }

    /// Interpolation output: strings verbatim, null as empty, scalars and
    /// JSON structures serialized.
    fn appendValueText(self: *Engine, v: std.json.Value) Error!void {
        try self.out.appendSlice(self.gpa, try self.scalarText(v));
    }

    fn objectGet(v: std.json.Value, key: []const u8) ?std.json.Value {
        return switch (v) {
            .object => |o| o.get(key),
            else => null,
        };
    }
};

fn unsafeScheme(url: []const u8) ?[]const u8 {
    const schemes = [_][]const u8{ "javascript:", "data:", "vbscript:" };
    for (schemes) |scheme| {
        if (url.len >= scheme.len and std.ascii.eqlIgnoreCase(url[0..scheme.len], scheme)) {
            return scheme[0 .. scheme.len - 1];
        }
    }
    return null;
}

pub fn truthy(v: std.json.Value) bool {
    return switch (v) {
        .null => false,
        .bool => |b| b,
        .integer => |i| i != 0,
        .float => |f| f != 0,
        .number_string => |s| s.len > 0 and std.mem.eql(u8, s, "0") == false,
        .string => |s| s.len > 0,
        .array => |a| a.items.len > 0,
        .object => |o| o.count() > 0,
    };
}

pub fn typeName(v: std.json.Value) []const u8 {
    return switch (v) {
        .string => "string",
        .null => "null",
        .bool => "boolean",
        .integer, .float, .number_string => "number",
        .array => "array",
        .object => "object",
    };
}

pub fn deepEqual(a: std.json.Value, b: std.json.Value) bool {
    const pair = struct {
        fn num(x: std.json.Value) ?f64 {
            return switch (x) {
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                else => null,
            };
        }
    };
    if (pair.num(a)) |na| {
        if (pair.num(b)) |nb| return na == nb;
        return false;
    }
    if (pair.num(b) != null) return false;
    return switch (a) {
        .string => |s| b == .string and std.mem.eql(u8, s, b.string),
        .null => b == .null,
        .bool => |x| b == .bool and x == b.bool,
        .number_string => |s| b == .number_string and std.mem.eql(u8, s, b.number_string),
        .integer, .float => unreachable, // handled by the numeric fast path above
        .array => |x| blk: {
            if (b != .array or x.items.len != b.array.items.len) break :blk false;
            for (x.items, b.array.items) |ia, ib| {
                if (!deepEqual(ia, ib)) break :blk false;
            }
            break :blk true;
        },
        .object => |x| blk: {
            if (b != .object or x.count() != b.object.count()) break :blk false;
            var it = x.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!deepEqual(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn compare(a: std.json.Value, b: std.json.Value) ?std.math.Order {
    const an: ?f64 = switch (a) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
    const bn: ?f64 = switch (b) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
    if (an != null and bn != null) return std.math.order(an.?, bn.?);
    if (a == .string and b == .string) return std.mem.order(u8, a.string, b.string);
    return null;
}
