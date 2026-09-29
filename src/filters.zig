//! Filter registry. Names come from Knap's user-facing docs (knap.md/filters);
//! the *output* dialect is Textile, per the mapping table in README.md.
//! `code_block` is accepted as an alias of `codeblock` (docs spell it with an
//! underscore; the fixture corpus uses the bare form).

const std = @import("std");

pub const Tag = enum {
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    bold,
    italic,
    blockquote,
    code,
    codeblock,
    link,
    list,
    numbered,
    table,
};

pub const Arity = enum { none, required, optional };

pub const Filter = struct { tag: Tag, arity: Arity };

const map = std.StaticStringMap(Filter).initComptime(.{
    .{ "h1", Filter{ .tag = .h1, .arity = .none } },
    .{ "h2", Filter{ .tag = .h2, .arity = .none } },
    .{ "h3", Filter{ .tag = .h3, .arity = .none } },
    .{ "h4", Filter{ .tag = .h4, .arity = .none } },
    .{ "h5", Filter{ .tag = .h5, .arity = .none } },
    .{ "h6", Filter{ .tag = .h6, .arity = .none } },
    .{ "bold", Filter{ .tag = .bold, .arity = .none } },
    .{ "italic", Filter{ .tag = .italic, .arity = .none } },
    .{ "blockquote", Filter{ .tag = .blockquote, .arity = .none } },
    .{ "code", Filter{ .tag = .code, .arity = .optional } },
    .{ "codeblock", Filter{ .tag = .codeblock, .arity = .none } },
    .{ "code_block", Filter{ .tag = .codeblock, .arity = .none } },
    .{ "link", Filter{ .tag = .link, .arity = .required } },
    .{ "list", Filter{ .tag = .list, .arity = .none } },
    .{ "numbered", Filter{ .tag = .numbered, .arity = .none } },
    .{ "table", Filter{ .tag = .table, .arity = .none } },
});

pub fn lookup(name: []const u8) ?Filter {
    return map.get(name);
}
