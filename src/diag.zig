//! Diagnostics: every failure carries a class, a 1-based line/column into the
//! template, and a message. Formatting is pinned by fixtures/errors/*.error.

const std = @import("std");

pub const Kind = enum {
    syntax,
    render,
    unknown_filter,
    bad_argument,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .syntax => "syntax error",
            .render => "render error",
            .unknown_filter => "unknown filter",
            .bad_argument => "bad argument",
        };
    }
};

pub const Diag = struct {
    kind: Kind,
    line: u32,
    col: u32,
    msg: []const u8,

    pub fn format(self: Diag, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fmt.allocPrint(
            gpa,
            "{s} at line {d}, column {d}: {s}",
            .{ self.kind.label(), self.line, self.col, self.msg },
        );
    }
};

pub const Position = struct { line: u32, col: u32 };

/// 1-based line/column of byte offset `pos` in `src`.
pub fn lineCol(src: []const u8, pos: usize) Position {
    var line: u32 = 1;
    var col: u32 = 1;
    const end = @min(pos, src.len);
    for (src[0..end]) |ch| {
        if (ch == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}
