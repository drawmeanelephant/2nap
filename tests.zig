//! Fixture-corpus test harness.
//!
//! Three layers of protection, per the spec:
//!   1. Byte-exact: every fixture triple must render to its expected Textile
//!      bytes exactly; every error fixture must produce the pinned diagnostic.
//!   2. Anti-passthrough: expected output differs from the template bytes in
//!      every fixture, so an engine that echoes the template fails everything.
//!   3. Anti-Markdown: no expected output contains unambiguous Markdown
//!      syntax, and every filter fixture's output carries its Textile marker
//!      — a filter that emitted Markdown fails both the byte comparison and
//!      these guards.
//!
//! Fixtures live in <repo>/fixtures; the root is located by walking up from
//! the current working directory.

const std = @import("std");
const diag = @import("src/diag.zig");
const parse = @import("src/parse.zig");
const engine = @import("src/engine.zig");
const filters = @import("src/filters.zig");

const gpa = std.heap.page_allocator;

// One Io instance shared by all tests (file reads and directory iteration),
// initialized lazily on first use — container-level initializers must stay
// comptime-evaluable, and Threaded.init is a runtime operation.
var threaded: std.Io.Threaded = undefined;
var io_opt: ?std.Io = null;

fn io() std.Io {
    if (io_opt == null) {
        threaded = .init(gpa, .{});
        io_opt = threaded.io();
    }
    return io_opt.?;
}

const Outcome = struct {
    out: []const u8 = "",
    err: ?diag.Diag = null,
};

fn runCase(knap_src: []const u8, json_src: []const u8) !Outcome {
    const parsed = try parse.parse(gpa, knap_src);
    var template = switch (parsed) {
        .failure => |f| {
            // Keep f.diag: its message lives in f.arena, deliberately leaked
            // (page allocator, test process lifetime).
            return .{ .err = f.diag };
        },
        .template => |t| t,
    };
    defer template.deinit();

    const data_parsed = std.json.parseFromSlice(std.json.Value, gpa, json_src, .{}) catch {
        std.debug.print("invalid JSON in test case: {s}\n", .{json_src});
        return error.TestUnexpectedResult;
    };
    defer data_parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    var render_err: ?diag.Diag = null;
    engine.render(gpa, &template, data_parsed.value, &out, &render_err) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Render => return .{ .out = out.items, .err = render_err.? },
    };
    return .{ .out = out.items };
}

fn renderCase(knap_src: []const u8, json_src: []const u8) ![]const u8 {
    const res = try runCase(knap_src, json_src);
    if (res.err) |d| {
        std.debug.print("unexpected render error: {s}\n", .{try d.format(gpa)});
        return error.TestUnexpectedResult;
    }
    return res.out;
}

// ---- repo root discovery -----------------------------------------------------

var root_buf: [std.fs.max_path_bytes]u8 = undefined;
var probe_buf: [std.fs.max_path_bytes]u8 = undefined;

fn repoRoot() ![]const u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io(), &cwd_buf);
    var dir: []const u8 = cwd_buf[0..n];
    while (true) {
        const probe = try std.fmt.bufPrint(&probe_buf, "{s}/fixtures", .{dir});
        if (std.Io.Dir.accessAbsolute(io(), probe, .{})) |_| {
            return std.fmt.bufPrint(&root_buf, "{s}", .{dir});
        } else |_| {}
        const parent = std.fs.path.dirname(dir) orelse return error.RootNotFound;
        if (parent.len == dir.len) return error.RootNotFound;
        dir = parent;
    }
}

fn join(dir: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
}

fn readDirStems(dir_path: []const u8, suffix: []const u8) ![][]const u8 {
    var stems: std.ArrayList([]const u8) = .empty;
    var d = try std.Io.Dir.openDirAbsolute(io(), dir_path, .{ .iterate = true });
    defer d.close(io());
    var it = d.iterate();
    while (try it.next(io())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        try stems.append(gpa, try gpa.dupe(u8, entry.name[0 .. entry.name.len - suffix.len]));
    }
    std.mem.sort([]const u8, stems.items, {}, lessThanStr);
    return stems.toOwnedSlice(gpa);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn readFixture(comptime fmt: []const u8, args: anytype) []const u8 {
    const path = std.fmt.allocPrint(gpa, fmt, args) catch unreachable;
    return std.Io.Dir.cwd().readFileAlloc(io(), path, gpa, .limited(1 << 24)) catch "";
}

const Triple = struct { stem: []const u8, knap: []const u8, json: []const u8, expected: []const u8 };

fn loadTriples() ![]Triple {
    const root = try repoRoot();
    const stems = try readDirStems(try join(root, "fixtures"), ".textile");
    var triples: std.ArrayList(Triple) = .empty;
    for (stems) |stem| {
        try triples.append(gpa, .{
            .stem = stem,
            .knap = readFixture("{s}/fixtures/{s}.knap", .{ root, stem }),
            .json = blk: {
                const j = readFixture("{s}/fixtures/{s}.json", .{ root, stem });
                break :blk if (j.len == 0) "{}" else j;
            },
            .expected = readFixture("{s}/fixtures/{s}.textile", .{ root, stem }),
        });
    }
    return triples.toOwnedSlice(gpa);
}

const ErrorCase = struct { stem: []const u8, knap: []const u8, json: []const u8, expected_msg: []const u8 };

fn loadErrorCases() ![]ErrorCase {
    const root = try repoRoot();
    const dir_path = try join(root, "fixtures/errors");
    const stems = try readDirStems(dir_path, ".error");
    var cases: std.ArrayList(ErrorCase) = .empty;
    for (stems) |stem| {
        const knap = readFixture("{s}/fixtures/errors/{s}.knap", .{ root, stem });
        const json = blk: {
            const j = readFixture("{s}/fixtures/errors/{s}.json", .{ root, stem });
            break :blk if (j.len == 0) "{}" else j;
        };
        const msg_file = readFixture("{s}/fixtures/errors/{s}.error", .{ root, stem });
        try cases.append(gpa, .{
            .stem = stem,
            .knap = knap,
            .json = json,
            .expected_msg = std.mem.trimEnd(u8, msg_file, "\n"),
        });
    }
    return cases.toOwnedSlice(gpa);
}

// ---- 1. byte-exact corpus ------------------------------------------------------

test "positive corpus renders byte-exact Textile" {
    const triples = try loadTriples();
    try std.testing.expect(triples.len > 0);
    for (triples) |fx| {
        const got = try renderCase(fx.knap, fx.json);
        std.testing.expectEqualStrings(fx.expected, got) catch |e| {
            std.debug.print("fixture {s} mismatch:\n--- expected ---\n{s}\n--- got ---\n{s}\n", .{ fx.stem, fx.expected, got });
            return e;
        };
    }
}

test "error corpus produces the pinned diagnostics" {
    const cases = try loadErrorCases();
    try std.testing.expect(cases.len > 0);
    for (cases) |case| {
        const res = try runCase(case.knap, case.json);
        if (res.err == null) {
            std.debug.print("fixture {s}: expected an error, got output {s}\n", .{ case.stem, res.out });
            return error.TestUnexpectedResult;
        }
        const msg = try res.err.?.format(gpa);
        std.testing.expectEqualStrings(case.expected_msg, msg) catch |e| {
            std.debug.print("fixture {s}: error message mismatch\n--- expected ---\n{s}\n--- got ---\n{s}\n", .{ case.stem, case.expected_msg, msg });
            return e;
        };
    }
}

// ---- 2. anti-passthrough invariants ---------------------------------------------

fn hasTextileMarker(stem: []const u8, out: []const u8) bool {
    const family_markers = [_]struct { needle: []const u8, marker: []const u8 }{
        .{ .needle = "filter-codeblock", .marker = "bc. " },
        .{ .needle = "filter-code", .marker = "@" },
        .{ .needle = "filter-link", .marker = "\":" },
        .{ .needle = "filter-table", .marker = "|_. " },
        .{ .needle = "filter-list", .marker = "* " },
        .{ .needle = "filter-numbered", .marker = "# " },
        .{ .needle = "filter-bold", .marker = "*" },
        .{ .needle = "filter-italic", .marker = "_" },
        .{ .needle = "filter-blockquote", .marker = "bq. " },
        .{ .needle = "filter-chain", .marker = "h2. " },
        .{ .needle = "filter-h1", .marker = "h1. " },
        .{ .needle = "filter-h2", .marker = "h2. " },
        .{ .needle = "filter-h3", .marker = "h3. " },
        .{ .needle = "filter-h4", .marker = "h4. " },
        .{ .needle = "filter-h5", .marker = "h5. " },
        .{ .needle = "filter-h6", .marker = "h6. " },
    };
    for (family_markers) |fm| {
        if (std.mem.indexOf(u8, stem, fm.needle) != null) {
            return std.mem.indexOf(u8, out, fm.marker) != null;
        }
    }
    return true; // non-filter fixtures carry no single family marker
}

/// Unambiguous Markdown emissions. (Nested Textile lists legitimately emit
/// `** `/`## ` at line start, and `bc.` content may contain `#` — those are
/// excluded from the forbidden set on purpose. See README dialect notes.)
fn containsMarkdown(bytes: []const u8) bool {
    var i: usize = 0;
    var line_start = true;
    while (i < bytes.len) : (i += 1) {
        const ch = bytes[i];
        if (line_start and ch == '>' and i + 1 < bytes.len and bytes[i + 1] == ' ') return true;
        line_start = ch == '\n';
        if (ch != '*' and ch != '~' and ch != '_' and ch != '`' and ch != ']') continue;
        if (ch == '*' and i + 2 < bytes.len and bytes[i + 1] == '*' and bytes[i + 2] != ' ') return true;
        if (ch == '~' and i + 1 < bytes.len and bytes[i + 1] == '~') return true;
        if (ch == '_' and i + 1 < bytes.len and bytes[i + 1] == '_') return true;
        if (ch == '`' and i + 2 < bytes.len and bytes[i + 1] == '`' and bytes[i + 2] == '`') return true;
        if (ch == ']' and i + 1 < bytes.len and bytes[i + 1] == '(') return true;
    }
    return false;
}

test "corpus invariants: no passthrough, no Markdown, Textile markers present" {
    const triples = try loadTriples();
    for (triples) |fx| {
        if (std.mem.eql(u8, fx.expected, fx.knap)) {
            std.debug.print("fixture {s}: expected output equals template (passthrough would pass)\n", .{fx.stem});
            return error.TestUnexpectedResult;
        }
        if (containsMarkdown(fx.expected)) {
            std.debug.print("fixture {s}: expected output contains Markdown syntax\n", .{fx.stem});
            return error.TestUnexpectedResult;
        }
        if (!hasTextileMarker(fx.stem, fx.expected)) {
            std.debug.print("fixture {s}: expected output lacks its Textile family marker\n", .{fx.stem});
            return error.TestUnexpectedResult;
        }
    }
}

// ---- 3. inline unit checks -------------------------------------------------------

test "missing variables render empty and are falsy" {
    const out = try renderCase("[{{ nope }}]{% if nope %}Y{% else %}N{% endif %}", "{}");
    try std.testing.expectEqualStrings("[]N", out);
}

test "truthiness table" {
    try std.testing.expect(!engine.truthy(.null));
    try std.testing.expect(!engine.truthy(.{ .bool = false }));
    try std.testing.expect(!engine.truthy(.{ .integer = 0 }));
    try std.testing.expect(!engine.truthy(.{ .string = "" }));
    try std.testing.expect(!engine.truthy(.{ .array = std.json.Array.init(gpa) }));
    try std.testing.expect(engine.truthy(.{ .string = "0" }));
    try std.testing.expect(engine.truthy(.{ .integer = -1 }));
}

test "loop variables expose index, index0, first, last, length" {
    const out = try renderCase(
        "{% for x in xs %}{{ loop.index0 }}:{{ loop.index }}:{{ loop.first }}:{{ loop.last }}:{{ loop.length }};{% endfor %}",
        "{\"xs\":[\"a\",\"b\"]}",
    );
    try std.testing.expectEqualStrings("0:1:true:false:2;1:2:false:true:2;", out);
}

test "whitespace rule: one newline after opening block tags" {
    const out = try renderCase("{% if true %}\nA\n{% endif %}\nend", "{}");
    try std.testing.expectEqualStrings("A\n\nend", out);
}

test "comments are removed without evaluation" {
    const out = try renderCase("a{# {{ x }} {% if %} #}b", "{}");
    try std.testing.expectEqualStrings("ab", out);
}

test "link filter refuses unsafe URL schemes" {
    const res = try runCase("{{ t | link:\"javascript:alert(1)\" }}", "{\"t\":\"x\"}");
    try std.testing.expect(res.err != null);
}

test "deep equality across integer and float" {
    try std.testing.expect(engine.deepEqual(.{ .integer = 5 }, .{ .float = 5.0 }));
    try std.testing.expect(!engine.deepEqual(.{ .integer = 5 }, .{ .string = "5" }));
}

test "every registered filter is a documented-registry member" {
    const names = [_][]const u8{ "h1", "h2", "h3", "h4", "h5", "h6", "bold", "italic", "blockquote", "code", "codeblock", "code_block", "link", "list", "numbered", "table" };
    for (names) |n| try std.testing.expect(filters.lookup(n) != null);
    try std.testing.expect(filters.lookup("nope") == null);
}

// Regressions from black-box differential observations, not oracle source.
test "bare filter arguments resolve only at the data root" {
    try std.testing.expectEqualStrings("\"name\":/root", try renderCase(
        "{% for url in urls %}{{ x | link:url }}{% endfor %}",
        "{\"x\":\"name\",\"url\":\"/root\",\"urls\":[\"/local\"]}",
    ));
    try std.testing.expectEqualStrings("\"name\":url", try renderCase("{{ x | link:\"url\" }}", "{\"x\":\"name\",\"url\":\"/root\"}"));
    try std.testing.expectEqualStrings("\"name\":fallback", try renderCase("{{ x | link:fallback }}", "{\"x\":\"name\"}"));
    for ([_][]const u8{ "null", "[]", "{}" }) |value| {
        const res = try runCase("{{ x | link:url }}", try std.fmt.allocPrint(gpa, "{{\"x\":\"name\",\"url\":{s}}}", .{value}));
        try std.testing.expect(res.err != null);
        try std.testing.expectEqual(diag.Kind.bad_argument, res.err.?.kind);
    }
}

test "empty objects are truthy and integer comparisons retain precision" {
    try std.testing.expect(engine.truthy(.{ .object = std.json.ObjectMap.empty }));
    try std.testing.expect(!engine.deepEqual(.{ .integer = 9007199254740992 }, .{ .integer = 9007199254740993 }));
    try std.testing.expectEqualStrings("yes", try renderCase(
        "{% if a < b %}yes{% else %}no{% endif %}",
        "{\"a\":9007199254740992,\"b\":9007199254740993}",
    ));
}

test "string escapes quote the next byte and bare CR is body text" {
    try std.testing.expectEqualStrings("anbtbrb", try renderCase("{{ \"a\\nb\\tb\\rb\" }}", "{}"));
    try std.testing.expectEqualStrings("\rA", try renderCase("{% if true %}\rA{% endif %}", "{}"));
    try std.testing.expectEqualStrings("A", try renderCase("{% if true %}\r\nA{% endif %}", "{}"));
    try std.testing.expectEqualStrings("", try renderCase("{% for loop in xs %}{{ loop.index }}{% endfor %}", "{\"xs\":[1,2]}"));
}

test "phrase filters and codeblocks reject structured inputs" {
    for ([_][]const u8{ "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "bold", "italic", "code", "codeblock", "link:\"/path\"" }) |filter| {
        const src = try std.fmt.allocPrint(gpa, "{{{{ x | {s} }}}}", .{filter});
        for ([_][]const u8{ "{\"x\":[]}", "{\"x\":{}}" }) |data| {
            try std.testing.expect((try runCase(src, data)).err != null);
        }
    }
    for ([_][]const u8{ "h1", "blockquote", "bold", "italic", "code" }) |filter| {
        const src = try std.fmt.allocPrint(gpa, "{{{{ x | {s} }}}}", .{filter});
        try std.testing.expect((try runCase(src, "{\"x\":\"a\\nb\"}")).err != null);
    }
    try std.testing.expectEqualStrings("bc. a\nb", try renderCase("{{ x | codeblock }}", "{\"x\":\"a\\nb\"}"));
}

test "Textile links and tables validate their delimiters" {
    const cases = [_]struct { src: []const u8, data: []const u8 }{
        .{ .src = "{{ x | link:\"\" }}", .data = "{\"x\":\"x\"}" },
        .{ .src = "{{ x | link:\"a b\" }}", .data = "{\"x\":\"x\"}" },
        .{ .src = "{{ x | link:\"/path\" }}", .data = "{\"x\":\"a\\\"b\"}" },
        .{ .src = "{{ x | table }}", .data = "{\"x\":[]}" },
        .{ .src = "{{ x | table }}", .data = "{\"x\":[[]]}" },
        .{ .src = "{{ x | table }}", .data = "{\"x\":[[\"a|b\"]]}" },
        .{ .src = "{{ x | table }}", .data = "{\"x\":[[\"a\\nb\"]]}" },
        .{ .src = "{{ x | list }}", .data = "{\"x\":[{}]}" },
    };
    for (cases) |c| try std.testing.expect((try runCase(c.src, c.data)).err != null);
}

test "logic tags accept multiline whitespace and reject trailing text" {
    try std.testing.expectEqualStrings("B", try renderCase("{%\nif true\nand false %}A{% else %}B{% endif %}", "{}"));
    const invalid = [_][]const u8{
        "{% if true junk %}A{% endif %}",
        "{% if true %}A{% endif junk %}",
        "{% if true %}A{% else junk %}B{% endif %}",
        "{% for x in xs %}A{% endfor junk %}",
        "{{ x .a }}",
        "{{ 1e3 }}",
    };
    for (invalid) |src| try std.testing.expect((try runCase(src, "{\"xs\":[1]}")).err != null);
}
