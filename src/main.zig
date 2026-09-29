//! CLI: knap-textile render <template.knap> [--data <data.json>]
//!
//! Contract: Textile bytes on stdout, exit 0 on success. Any failure prints
//! one `knap-textile: error: ...` line to stderr and exits 1. Output is fully
//! buffered: stdout is written only after a complete, successful render.

const std = @import("std");
const diag = @import("diag.zig");
const parse = @import("parse.zig");
const engine = @import("engine.zig");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const alloc = init.arena.allocator();

    var args_list: std.ArrayList([]const u8) = .empty;
    {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
        defer it.deinit();
        while (it.next()) |a| try args_list.append(alloc, a);
    }
    const argv = args_list.items;

    if (argv.len < 2 or !std.mem.eql(u8, argv[1], "render") or argv.len < 3) {
        return fail(io, alloc, "usage: knap-textile render <template.knap> [--data <data.json>]", .{});
    }
    const template_path = argv[2];

    var data_path: ?[]const u8 = null;
    var i: usize = 3;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--data")) {
            if (i + 1 >= argv.len) {
                return fail(io, alloc, "--data requires a file argument", .{});
            }
            i += 1;
            data_path = argv[i];
        } else if (std.mem.startsWith(u8, arg, "--data=")) {
            data_path = arg["--data=".len..];
        } else {
            return fail(io, alloc, "unknown argument '{s}'; usage: knap-textile render <template.knap> [--data <data.json>]", .{arg});
        }
    }

    // 1. Read and parse the template (before touching data, so template syntax
    //    errors surface even without a data file).
    const src = std.Io.Dir.cwd().readFileAlloc(io, template_path, alloc, .limited(1 << 26)) catch |e| {
        return fail(io, alloc, "cannot read template file '{s}': {s}", .{ template_path, @errorName(e) });
    };

    const parsed = try parse.parse(alloc, src);
    var template = switch (parsed) {
        .failure => |f| {
            const msg = try f.diag.format(alloc);
            return fail(io, alloc, "{s}", .{msg});
        },
        .template => |t| t,
    };
    defer template.deinit();

    // 2. Load data.
    var data: std.json.Value = undefined;
    if (data_path) |dp| {
        const json_bytes = std.Io.Dir.cwd().readFileAlloc(io, dp, alloc, .limited(1 << 26)) catch |e| {
            return fail(io, alloc, "cannot read data file '{s}': {s}", .{ dp, @errorName(e) });
        };
        const json_parsed = std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{}) catch |e| {
            return fail(io, alloc, "invalid JSON data in '{s}': {s}", .{ dp, @errorName(e) });
        };
        data = json_parsed.value;
    } else {
        data = .{ .object = std.json.ObjectMap.empty };
    }

    // 3. Render fully into memory; write stdout only on success.
    var out: std.ArrayList(u8) = .empty;
    var render_err: ?diag.Diag = null;
    engine.render(alloc, &template, data, &out, &render_err) catch |e| switch (e) {
        error.OutOfMemory => return fail(io, alloc, "out of memory", .{}),
        error.Render => {
            const msg = try render_err.?.format(alloc);
            return fail(io, alloc, "{s}", .{msg});
        },
    };

    var stdout_buf: [4096]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stdout(), io, &stdout_buf);
    w.interface.writeAll(out.items) catch |e| {
        return fail(io, alloc, "cannot write to stdout: {s}", .{@errorName(e)});
    };
    w.flush() catch |e| {
        return fail(io, alloc, "cannot write to stdout: {s}", .{@errorName(e)});
    };
    return 0;
}

fn fail(io: std.Io, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) noreturn {
    const msg = std.fmt.allocPrint(alloc, "knap-textile: error: " ++ fmt ++ "\n", args) catch "knap-textile: error\n";
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stderr(), io, &buf);
    w.interface.writeAll(msg) catch {};
    w.flush() catch {};
    std.process.exit(1);
}
