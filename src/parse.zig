//! Template parser: Knap-subset templates -> AST.
//!
//! Grammar (clean-room from knap.md/variables, /filters, /logic):
//!   template := (text | comment | output | block)*
//!   comment  := {# ... #}                       (removed, ends at first #})
//!   output   := {{ value (| filter(:arg)?)* }}   (value: literal or path)
//!   block    := {% if expr %} ... {% elseif expr %} ... {% else %} ... {% endif %}
//!             | {% for name in expr %} ... {% endfor %}
//!
//! Whitespace rule (pinned by the fixture corpus): one newline immediately
//! after an opening block tag (if/elseif/else/for) is consumed; a newline
//! before a closing tag is preserved as body text.
//!
//! Error positions are pinned by fixtures/errors/*.error:
//!   - unclosed blocks/comments/tags report at their opening delimiter
//!   - stray block tags report just after the tag keyword
//!   - "expected a value" reports at the position where a value was required
//!   - filter errors (unknown/bad-arg) report at the filter name

const std = @import("std");
const diag = @import("diag.zig");
const filters = @import("filters.zig");

pub const Diag = diag.Diag;
pub const Error = error{ Parse, OutOfMemory };

pub const max_nesting: u32 = 64;

pub const Segment = union(enum) {
    dot: []const u8,
    index: usize,
    key: []const u8,
};

pub const Path = struct {
    root: []const u8,
    segments: []const Segment,
};

pub const Literal = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
    nul: void,
};

pub const BinOp = enum { eq, ne, lt, le, gt, ge, contains, and_, or_ };

pub const Expr = union(enum) {
    literal: Literal,
    path: Path,
    not: *Expr,
    binary: struct { op: BinOp, lhs: *Expr, rhs: *Expr },
};

pub const FilterArg = union(enum) { string: []const u8, bare: []const u8, int: i64, float: f64 };

pub const FilterCall = struct {
    name: []const u8,
    arg: ?FilterArg,
    /// byte offset of the filter name (error position for render-time failures)
    pos: usize,
};

pub const Output = struct {
    expr: Expr,
    filters: []const FilterCall,
};

pub const IfBranch = struct {
    /// null for the {% else %} branch
    cond: ?Expr,
    body: []const Node,
};

pub const If = struct {
    /// byte offset of the opening {% if %} (error position when unclosed)
    pos: usize,
    branches: []const IfBranch,
};

pub const For = struct {
    pos: usize,
    iter: []const u8,
    expr: Expr,
    body: []const Node,
};

pub const Node = union(enum) {
    text: []const u8,
    output: Output,
    if_: If,
    for_: For,
};

pub const Template = struct {
    arena: std.heap.ArenaAllocator,
    nodes: []const Node,
    src: []const u8,

    pub fn deinit(self: *Template) void {
        self.arena.deinit();
    }
};

/// Outcome of parsing. On failure the diagnostic message lives in the
/// returned arena: read `failure.diag`, then `failure.arena.deinit()`.
pub const Parsed = union(enum) {
    template: Template,
    failure: struct { diag: Diag, arena: std.heap.ArenaAllocator },
};

pub fn parse(gpa: std.mem.Allocator, src: []const u8) std.mem.Allocator.Error!Parsed {
    var p = Parser{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .src = src,
    };
    const top = p.parseBody(.none, 0, 0) catch |e| switch (e) {
        error.OutOfMemory => {
            p.arena.deinit();
            return error.OutOfMemory;
        },
        error.Parse => {
            return .{ .failure = .{ .diag = p.err.?, .arena = p.arena } };
        },
    };
    return .{ .template = .{ .arena = p.arena, .nodes = top.nodes, .src = src } };
}

const Terminator = enum { none, if_block, for_block };

const Term = enum { eof, elseif, else_, endif, endfor };

const BodyResult = struct {
    nodes: []const Node,
    term: Term,
    /// index of the '%' of the terminating tag's '%}'; meaningful when term != .eof
    close: usize = 0,
    /// index just after the terminating tag's keyword
    kw_end: usize = 0,
};

const Parser = struct {
    arena: std.heap.ArenaAllocator,
    src: []const u8,
    pos: usize = 0,
    err: ?Diag = null,

    fn alloc(self: *Parser) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn failAt(self: *Parser, kind: diag.Kind, pos: usize, comptime fmt: []const u8, args: anytype) error{ Parse, OutOfMemory } {
        if (self.err == null) {
            const lc = diag.lineCol(self.src, pos);
            self.err = .{
                .kind = kind,
                .line = lc.line,
                .col = lc.col,
                .msg = try std.fmt.allocPrint(self.alloc(), fmt, args),
            };
        }
        return error.Parse;
    }

    // ---- low-level scanning -------------------------------------------------

    fn eof(self: *Parser) bool {
        return self.pos >= self.src.len;
    }

    fn peek(self: *Parser) u8 {
        return if (self.eof()) 0 else self.src[self.pos];
    }

    fn startsWith(self: *Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, self.src[self.pos..], s);
    }

    fn skipWs(self: *Parser) void {
        while (!self.eof() and (self.peek() == ' ' or self.peek() == '\t' or self.peek() == '\r' or self.peek() == '\n')) {
            self.pos += 1;
        }
    }

    fn skipSpaces(self: *Parser) void {
        while (!self.eof() and (self.peek() == ' ' or self.peek() == '\t')) {
            self.pos += 1;
        }
    }

    /// Consume exactly one LF or CRLF. A bare CR is body text.
    fn consumeOneNewline(self: *Parser) void {
        if (self.eof()) return;
        if (self.peek() == '\r') {
            if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\n') {
                self.pos += 2;
            }
        } else if (self.peek() == '\n') {
            self.pos += 1;
        }
    }

    fn isWordChar(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_';
    }

    /// Characters allowed inside a variable name in interpolation. Variable
    /// *output* supports names with spaces (knap.md/variables), so space is
    /// included here and trimmed by the caller. Logic tags use the stricter
    /// word charset so operators lex correctly.
    fn isNameChar(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == ' ' or ch == '\t' or ch >= 0x80;
    }

    /// Find the closing delimiter, optionally skipping over quoted strings.
    /// Returns the index of the closer, or null when unclosed.
    fn findClose(self: *Parser, from: usize, closer: []const u8, respect_quotes: bool) ?usize {
        var i = from;
        while (i < self.src.len) {
            const ch = self.src[i];
            if (respect_quotes and ch == '"') {
                i += 1;
                while (i < self.src.len) {
                    if (self.src[i] == '\\') {
                        i += 2;
                        continue;
                    }
                    if (self.src[i] == '"') break;
                    i += 1;
                }
                if (i >= self.src.len) return null;
                i += 1;
                continue;
            }
            if (std.mem.startsWith(u8, self.src[i..], closer)) return i;
            i += 1;
        }
        return null;
    }

    const Opener = enum { output, block, comment };

    /// Advance the cursor to the next `{{`, `{%` or `{#`. Returns the opener
    /// kind, or null at EOF.
    fn nextOpener(self: *Parser) ?Opener {
        while (self.pos < self.src.len) {
            if (self.src[self.pos] == '{' and self.pos + 1 < self.src.len) {
                switch (self.src[self.pos + 1]) {
                    '{' => return .output,
                    '%' => return .block,
                    '#' => return .comment,
                    else => {},
                }
            }
            self.pos += 1;
        }
        return null;
    }

    // ---- template body ------------------------------------------------------

    fn parseBody(self: *Parser, until: Terminator, depth: u32, open_pos: usize) Error!BodyResult {
        var nodes: std.ArrayList(Node) = .empty;

        while (true) {
            const text_start = self.pos;
            const opener = self.nextOpener();
            if (text_start < self.pos) {
                try nodes.append(self.alloc(), .{ .text = self.src[text_start..self.pos] });
            }
            const start = self.pos;
            const kind = opener orelse {
                if (until != .none) {
                    return switch (until) {
                        .if_block => self.failAt(.syntax, open_pos, "unclosed if block (missing '{{% endif %}}')", .{}),
                        .for_block => self.failAt(.syntax, open_pos, "unclosed for block (missing '{{% endfor %}}')", .{}),
                        .none => unreachable,
                    };
                }
                return .{ .nodes = try nodes.toOwnedSlice(self.alloc()), .term = .eof };
            };
            switch (kind) {
                .comment => {
                    const close = self.findClose(start + 2, "#}", false) orelse
                        return self.failAt(.syntax, start, "unclosed comment (missing '#}}')", .{});
                    self.pos = close + 2;
                },
                .output => {
                    const out = try self.parseOutput(start);
                    try nodes.append(self.alloc(), .{ .output = out });
                },
                .block => {
                    const close = self.findClose(start + 2, "%}", true) orelse
                        return self.failAt(.syntax, start, "unclosed '{{%' tag (missing '%}}')", .{});
                    self.pos = start + 2;
                    self.skipWs();
                    const kw_start = self.pos;
                    while (!self.eof() and std.ascii.isAlphabetic(self.peek())) self.pos += 1;
                    const kw = self.src[kw_start..self.pos];
                    const kw_end = self.pos;

                    if (std.mem.eql(u8, kw, "if")) {
                        if (depth + 1 > max_nesting) {
                            return self.failAt(.syntax, kw_end, "nesting too deep (max {d} levels)", .{max_nesting});
                        }
                        const node = try self.parseIf(start, depth + 1, close);
                        try nodes.append(self.alloc(), .{ .if_ = node });
                    } else if (std.mem.eql(u8, kw, "for")) {
                        if (depth + 1 > max_nesting) {
                            return self.failAt(.syntax, kw_end, "nesting too deep (max {d} levels)", .{max_nesting});
                        }
                        const node = try self.parseFor(start, depth + 1, close);
                        try nodes.append(self.alloc(), .{ .for_ = node });
                    } else if (std.mem.eql(u8, kw, "elseif") or std.mem.eql(u8, kw, "else") or std.mem.eql(u8, kw, "endif")) {
                        if (until == .if_block) {
                            if (!std.mem.eql(u8, kw, "elseif")) try self.validateTerminator(close, kw);
                            self.pos = start;
                            return .{
                                .nodes = try nodes.toOwnedSlice(self.alloc()),
                                .term = if (std.mem.eql(u8, kw, "elseif"))
                                    Term.elseif
                                else if (std.mem.eql(u8, kw, "else"))
                                    Term.else_
                                else
                                    Term.endif,
                                .close = close,
                                .kw_end = kw_end,
                            };
                        }
                        return self.failAt(.syntax, kw_end, "unexpected '{{% {s} %}}' outside an if block", .{kw});
                    } else if (std.mem.eql(u8, kw, "endfor")) {
                        if (until == .for_block) {
                            try self.validateTerminator(close, kw);
                            self.pos = start;
                            return .{ .nodes = try nodes.toOwnedSlice(self.alloc()), .term = .endfor, .close = close, .kw_end = kw_end };
                        }
                        return self.failAt(.syntax, kw_end, "unexpected '{{% endfor %}}' outside a for block", .{});
                    } else {
                        return self.failAt(.syntax, kw_end, "unknown logic tag '{s}'", .{kw});
                    }
                },
            }
        }
    }

    /// Parse an `{% if %}` chain. Cursor sits just after the `if` keyword;
    /// `close` is the index of the '%' of this tag's '%}'.
    fn parseIf(self: *Parser, open_pos: usize, depth: u32, close: usize) Error!If {
        var branches: std.ArrayList(IfBranch) = .empty;

        var cond: ?Expr = try self.parseLogicExpr(close);
        try self.expectBlockClose(close, "unexpected text after condition");
        self.consumeOneNewline();

        while (true) {
            const res = try self.parseBody(.if_block, depth, open_pos);
            try branches.append(self.alloc(), .{ .cond = cond, .body = res.nodes });
            switch (res.term) {
                .eof, .endfor => unreachable, // parseBody already failed
                .endif => {
                    self.pos = res.close + 2;
                    return .{ .pos = open_pos, .branches = try branches.toOwnedSlice(self.alloc()) };
                },
                .elseif => {
                    // resume just after the elseif keyword, then parse its cond
                    self.pos = res.kw_end;
                    cond = try self.parseLogicExpr(res.close);
                    try self.expectBlockClose(res.close, "unexpected text after condition");
                    self.consumeOneNewline();
                },
                .else_ => {
                    self.pos = res.close + 2;
                    self.consumeOneNewline();
                    const res2 = try self.parseBody(.if_block, depth, open_pos);
                    try branches.append(self.alloc(), .{ .cond = null, .body = res2.nodes });
                    switch (res2.term) {
                        .endif => {
                            self.pos = res2.close + 2;
                            return .{ .pos = open_pos, .branches = try branches.toOwnedSlice(self.alloc()) };
                        },
                        .else_ => return self.failAt(.syntax, self.pos, "duplicate '{{% else %}}'", .{}),
                        .elseif => return self.failAt(.syntax, self.pos, "unexpected '{{% elseif %}}' after '{{% else %}}'", .{}),
                        else => unreachable,
                    }
                },
            }
        }
    }

    /// Parse `{% for name in expr %}`. Cursor sits just after the `for` keyword.
    fn parseFor(self: *Parser, open_pos: usize, depth: u32, close: usize) Error!For {
        self.skipWs();
        const name_start = self.pos;
        while (!self.eof() and isWordChar(self.peek())) self.pos += 1;
        const iter = self.src[name_start..self.pos];
        if (iter.len == 0) {
            return self.failAt(.syntax, self.pos, "expected a loop variable name after 'for'", .{});
        }
        self.skipWs();
        if (!(self.startsWith("in") and (self.pos + 2 >= self.src.len or !isWordChar(self.src[self.pos + 2])))) {
            return self.failAt(.syntax, self.pos, "expected 'in' in for tag", .{});
        }
        self.pos += 2;
        self.skipWs();
        const expr = try self.parseLogicExpr(close);
        try self.expectBlockClose(close, "unexpected text after the for expression");
        self.consumeOneNewline();

        const res = try self.parseBody(.for_block, depth, open_pos);
        self.pos = res.close + 2;
        return .{ .pos = open_pos, .iter = iter, .expr = expr, .body = res.nodes };
    }

    /// Consume the `%}` closing the current tag: the cursor must sit on the
    /// '%' (possibly after whitespace).
    fn expectBlockClose(self: *Parser, close: usize, comptime message: []const u8) Error!void {
        self.skipWs();
        if (self.pos != close) {
            return self.failAt(.syntax, self.pos, message, .{});
        }
        self.pos = close + 2;
    }

    fn validateTerminator(self: *Parser, close: usize, keyword: []const u8) Error!void {
        self.skipWs();
        if (self.pos != close) {
            return self.failAt(.syntax, self.pos, "unexpected text in '{{% {s} %}}'", .{keyword});
        }
    }

    // ---- output tags --------------------------------------------------------

    fn parseOutput(self: *Parser, open_pos: usize) Error!Output {
        _ = self.findClose(open_pos + 2, "}}", true) orelse
            return self.failAt(.syntax, open_pos, "unclosed '{{{{' tag (missing '}}}}')", .{});
        self.pos = open_pos + 2;
        self.skipWs();
        const expr = try self.parseOutputValue();

        self.skipWs();
        var calls: std.ArrayList(FilterCall) = .empty;
        while (self.peek() == '|') {
            self.pos += 1;
            self.skipWs();
            const name_start = self.pos;
            while (!self.eof() and isWordChar(self.peek())) self.pos += 1;
            const name = self.src[name_start..self.pos];
            if (name.len == 0) {
                return self.failAt(.syntax, name_start, "expected a filter name after '|'", .{});
            }
            self.skipWs();

            var arg: ?FilterArg = null;
            if (self.peek() == ':') {
                self.pos += 1;
                self.skipWs();
                arg = try self.parseFilterArg();
            }

            if (filters.lookup(name)) |f| {
                if (f.arity == .none and arg != null) {
                    return self.failAt(.bad_argument, name_start, "filter '{s}' takes no arguments", .{name});
                }
                if (f.arity == .required and arg == null) {
                    if (std.mem.eql(u8, name, "link")) {
                        return self.failAt(
                            .bad_argument,
                            name_start,
                            "filter 'link' requires a URL argument, e.g. link:\"https://example.com/\"",
                            .{},
                        );
                    }
                    return self.failAt(.bad_argument, name_start, "filter '{s}' requires an argument", .{name});
                }
            } else {
                return self.failAt(.unknown_filter, name_start, "no filter named \"{s}\"", .{name});
            }

            try calls.append(self.alloc(), .{ .name = name, .arg = arg, .pos = name_start });
            self.skipWs();
        }

        if (!self.startsWith("}}")) {
            return self.failAt(.syntax, self.pos, "unexpected text in output tag (expected '|' or end of tag)", .{});
        }
        self.pos += 2;
        return .{ .expr = expr, .filters = try calls.toOwnedSlice(self.alloc()) };
    }

    /// A value in interpolation: string/number/bool/null literal or a (possibly
    /// spaced) variable path. Spaced names are only allowed in output tags —
    /// logic tags use the strict word charset so operators lex correctly.
    fn parseOutputValue(self: *Parser) Error!Expr {
        const ch = self.peek();
        if (ch == '"') {
            const s = try self.parseStringLiteral();
            return .{ .literal = .{ .string = s } };
        }
        if (std.ascii.isDigit(ch) or (ch == '-' and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1]))) {
            return .{ .literal = try self.parseNumberLiteral() };
        }
        if (self.startsWith("true") and (self.pos + 4 >= self.src.len or !isWordChar(self.src[self.pos + 4]))) {
            self.pos += 4;
            return .{ .literal = .{ .boolean = true } };
        }
        if (self.startsWith("false") and (self.pos + 5 >= self.src.len or !isWordChar(self.src[self.pos + 5]))) {
            self.pos += 5;
            return .{ .literal = .{ .boolean = false } };
        }
        if (self.startsWith("null") and (self.pos + 4 >= self.src.len or !isWordChar(self.src[self.pos + 4]))) {
            self.pos += 4;
            return .{ .literal = .{ .nul = {} } };
        }
        if (isNameChar(ch)) {
            return .{ .path = try self.parsePath(true) };
        }
        return self.failAt(.syntax, self.pos, "expected a value", .{});
    }

    fn parseStringLiteral(self: *Parser) Error![]const u8 {
        // cursor on the opening quote
        self.pos += 1;
        var buf: std.ArrayList(u8) = .empty;
        while (!self.eof()) {
            const ch = self.src[self.pos];
            if (ch == '"') {
                self.pos += 1;
                return try buf.toOwnedSlice(self.alloc());
            }
            if (ch == '\\' and self.pos + 1 < self.src.len) {
                self.pos += 1;
                const esc = self.src[self.pos];
                // Knap string quoting escapes the next byte, not JSON escapes.
                try buf.append(self.alloc(), esc);
                self.pos += 1;
                continue;
            }
            try buf.append(self.alloc(), ch);
            self.pos += 1;
        }
        return self.failAt(.syntax, self.pos, "unclosed string literal", .{});
    }

    fn parseNumberLiteral(self: *Parser) Error!Literal {
        const start = self.pos;
        if (self.peek() == '-') self.pos += 1;
        var is_float = false;
        while (!self.eof()) {
            const ch = self.peek();
            if (std.ascii.isDigit(ch)) {
                self.pos += 1;
            } else if (ch == '.' and !is_float and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1])) {
                is_float = true;
                self.pos += 1;
            } else break;
        }
        const text = self.src[start..self.pos];
        if (self.peek() == 'e' or self.peek() == 'E') {
            return self.failAt(.syntax, self.pos, "invalid number literal", .{});
        }
        if (is_float) {
            const f = std.fmt.parseFloat(f64, text) catch
                return self.failAt(.syntax, self.pos, "invalid number literal", .{});
            return .{ .float = f };
        }
        const i = std.fmt.parseInt(i64, text, 10) catch
            return self.failAt(.syntax, self.pos, "invalid number literal", .{});
        return .{ .int = i };
    }

    fn parseFilterArg(self: *Parser) Error!FilterArg {
        const ch = self.peek();
        if (ch == '"') {
            return .{ .string = try self.parseStringLiteral() };
        }
        if (std.ascii.isDigit(ch) or (ch == '-' and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1]))) {
            const lit = try self.parseNumberLiteral();
            return switch (lit) {
                .int => |i| FilterArg{ .int = i },
                .float => |f| FilterArg{ .float = f },
                else => unreachable,
            };
        }
        // bare word argument, e.g. hr:before
        const start = self.pos;
        while (!self.eof() and (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_' or self.peek() == '-')) {
            self.pos += 1;
        }
        if (self.pos == start) {
            return self.failAt(.syntax, start, "expected a filter argument after ':'", .{});
        }
        return .{ .bare = self.src[start..self.pos] };
    }

    /// A variable path: root name with `.name`, `[n]` and `["key"]` segments.
    fn parsePath(self: *Parser, allow_spaces: bool) Error!Path {
        var segments: std.ArrayList(Segment) = .empty;

        const root = try self.parseNameChunk(allow_spaces);
        if (root.len == 0) {
            return self.failAt(.syntax, self.pos, "expected a value", .{});
        }

        while (!self.eof()) {
            const ch = self.peek();
            if (ch == '.') {
                self.pos += 1;
                self.skipSpaces();
                const name = try self.parseNameChunk(allow_spaces);
                if (name.len == 0) {
                    return self.failAt(.syntax, self.pos, "expected a variable name", .{});
                }
                try segments.append(self.alloc(), .{ .dot = name });
            } else if (ch == '[') {
                self.pos += 1;
                self.skipSpaces();
                if (self.peek() == '"') {
                    const key = try self.parseStringLiteral();
                    self.skipSpaces();
                    if (self.peek() != ']') {
                        return self.failAt(.syntax, self.pos, "expected ']' after bracket key", .{});
                    }
                    self.pos += 1;
                    try segments.append(self.alloc(), .{ .key = key });
                } else if (std.ascii.isDigit(self.peek())) {
                    const idx_start = self.pos;
                    while (!self.eof() and std.ascii.isDigit(self.peek())) self.pos += 1;
                    const n = std.fmt.parseInt(usize, self.src[idx_start..self.pos], 10) catch
                        return self.failAt(.syntax, self.pos, "invalid array index", .{});
                    self.skipSpaces();
                    if (self.peek() != ']') {
                        return self.failAt(.syntax, self.pos, "expected ']' after array index", .{});
                    }
                    self.pos += 1;
                    try segments.append(self.alloc(), .{ .index = n });
                } else {
                    if (self.startsWith("}}") or self.startsWith("%}")) {
                        return self.failAt(.syntax, self.pos, "unclosed '[' in path", .{});
                    }
                    return self.failAt(.syntax, self.pos, "bracket access supports a number or a quoted key", .{});
                }
            } else break;
        }

        return .{ .root = root, .segments = try segments.toOwnedSlice(self.alloc()) };
    }

    /// Read one name chunk. When `allow_spaces`, the chunk may contain spaces;
    /// trailing whitespace is trimmed so `{{ name }}` and `{{ name | f }}` both
    /// yield the bare name.
    fn parseNameChunk(self: *Parser, allow_spaces: bool) Error![]const u8 {
        const start = self.pos;
        while (!self.eof()) {
            const ch = self.peek();
            const ok = if (allow_spaces) isNameChar(ch) else isWordChar(ch);
            if (!ok) break;
            self.pos += 1;
        }
        var name = self.src[start..self.pos];
        if (allow_spaces) {
            name = std.mem.trim(u8, name, " \t");
            // Keep trailing whitespace outside the path. A property/index
            // suffix must adjoin the preceding name, not follow a space.
            self.pos = start + name.len;
        }
        return name;
    }

    // ---- logic expressions --------------------------------------------------

    fn parseLogicExpr(self: *Parser, inner_end: usize) Error!Expr {
        return self.parseOr(inner_end);
    }

    /// True when the cursor is at `inner_end` (modulo trailing spaces).
    fn atInnerEnd(self: *Parser, inner_end: usize) bool {
        var i = self.pos;
        while (i < inner_end and std.ascii.isWhitespace(self.src[i])) i += 1;
        return i >= inner_end;
    }

    /// True when `word` sits at the cursor as a whole word within the tag.
    fn peekWord(self: *Parser, word: []const u8, inner_end: usize) bool {
        if (!self.startsWith(word)) return false;
        const after = self.pos + word.len;
        if (after > inner_end) return false;
        if (after >= self.src.len) return true;
        return !isWordChar(self.src[after]);
    }

    fn parseOr(self: *Parser, inner_end: usize) Error!Expr {
        var lhs = try self.alloc().create(Expr);
        lhs.* = try self.parseAnd(inner_end);
        while (true) {
            const save = self.pos;
            self.skipWs();
            var op: ?BinOp = null;
            if (self.startsWith("||")) {
                self.pos += 2;
                op = .or_;
            } else if (self.peekWord("or", inner_end)) {
                self.pos += 2;
                op = .or_;
            }
            if (op == null) {
                self.pos = save;
                return lhs.*;
            }
            self.skipWs();
            const rhs = try self.alloc().create(Expr);
            rhs.* = try self.parseAnd(inner_end);
            const node = try self.alloc().create(Expr);
            node.* = .{ .binary = .{ .op = op.?, .lhs = lhs, .rhs = rhs } };
            lhs = node;
        }
    }

    fn parseAnd(self: *Parser, inner_end: usize) Error!Expr {
        var lhs = try self.alloc().create(Expr);
        lhs.* = try self.parseNot(inner_end);
        while (true) {
            const save = self.pos;
            self.skipWs();
            var op: ?BinOp = null;
            if (self.startsWith("&&")) {
                self.pos += 2;
                op = .and_;
            } else if (self.peekWord("and", inner_end)) {
                self.pos += 3;
                op = .and_;
            }
            if (op == null) {
                self.pos = save;
                return lhs.*;
            }
            self.skipWs();
            const rhs = try self.alloc().create(Expr);
            rhs.* = try self.parseNot(inner_end);
            const node = try self.alloc().create(Expr);
            node.* = .{ .binary = .{ .op = op.?, .lhs = lhs, .rhs = rhs } };
            lhs = node;
        }
    }

    fn parseNot(self: *Parser, inner_end: usize) Error!Expr {
        const save = self.pos;
        self.skipWs();
        if (self.peek() == '!' and !(self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=')) {
            self.pos += 1;
            const operand = try self.alloc().create(Expr);
            operand.* = try self.parseNot(inner_end);
            return .{ .not = operand };
        }
        if (self.peekWord("not", inner_end)) {
            self.pos += 3;
            const operand = try self.alloc().create(Expr);
            operand.* = try self.parseNot(inner_end);
            return .{ .not = operand };
        }
        self.pos = save;
        return self.parseCompare(inner_end);
    }

    fn parseCompare(self: *Parser, inner_end: usize) Error!Expr {
        const lhs = try self.alloc().create(Expr);
        lhs.* = try self.parsePrimary(inner_end);
        const save = self.pos;
        self.skipWs();
        var op: ?BinOp = null;
        if (self.startsWith("==")) {
            self.pos += 2;
            op = .eq;
        } else if (self.startsWith("!=")) {
            self.pos += 2;
            op = .ne;
        } else if (self.startsWith("<=")) {
            self.pos += 2;
            op = .le;
        } else if (self.startsWith(">=")) {
            self.pos += 2;
            op = .ge;
        } else if (self.startsWith("<")) {
            self.pos += 1;
            op = .lt;
        } else if (self.startsWith(">")) {
            self.pos += 1;
            op = .gt;
        } else if (self.peekWord("contains", inner_end)) {
            self.pos += 8;
            op = .contains;
        }
        if (op == null) {
            self.pos = save;
            return lhs.*;
        }
        self.skipWs();
        const rhs = try self.alloc().create(Expr);
        rhs.* = try self.parsePrimary(inner_end);
        const node = try self.alloc().create(Expr);
        node.* = .{ .binary = .{ .op = op.?, .lhs = lhs, .rhs = rhs } };
        return node.*;
    }

    fn parsePrimary(self: *Parser, inner_end: usize) Error!Expr {
        self.skipWs();
        if (self.atInnerEnd(inner_end) or self.peek() == '%') {
            return self.failAt(.syntax, self.pos, "expected a value", .{});
        }
        if (self.peek() == '(') {
            self.pos += 1;
            const e = try self.parseOr(inner_end);
            self.skipWs();
            if (self.peek() != ')') {
                return self.failAt(.syntax, self.pos, "expected ')'", .{});
            }
            self.pos += 1;
            return e;
        }
        const ch = self.peek();
        if (ch == '"') {
            const s = try self.parseStringLiteral();
            return .{ .literal = .{ .string = s } };
        }
        if (std.ascii.isDigit(ch) or (ch == '-' and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1]))) {
            return .{ .literal = try self.parseNumberLiteral() };
        }
        if (self.peekWord("true", inner_end)) {
            self.pos += 4;
            return .{ .literal = .{ .boolean = true } };
        }
        if (self.peekWord("false", inner_end)) {
            self.pos += 5;
            return .{ .literal = .{ .boolean = false } };
        }
        if (self.peekWord("null", inner_end)) {
            self.pos += 4;
            return .{ .literal = .{ .nul = {} } };
        }
        if (isWordChar(ch)) {
            return .{ .path = try self.parsePath(false) };
        }
        return self.failAt(.syntax, self.pos, "expected a value", .{});
    }
};
