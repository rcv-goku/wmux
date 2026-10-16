//! When-clause parser and evaluator for shortcut contexts (ADR-8.5).
//!
//! Grammar (cmux semantics, VS Code style):
//!   or      := and ('||' and)*
//!   and     := unary ('&&' unary)*
//!   unary   := '!' unary | primary
//!   primary := '(' or ')' | 'true' | 'false'
//!            | key [ ('=='|'!='|'<'|'<='|'>'|'>=') value
//!                  | '=~' regex | 'in' '[' value (',' value)* ']' ]
//!   value   := 'single' | "double" | integer | true | false | bareword
//!   regex   := /pattern/flags | 'string'
//! Comparisons bind tighter than && and ||. Unknown or absent keys read as
//! false; `key == false` equals `!key`. Regexes support literals, `.`, `^`,
//! `$`, `* + ?`, `[...]` classes (ranges, negation) and `\` escapes; flag `i`
//! folds ASCII case.

const std = @import("std");

/// Context keys computed by `input/context.zig` (ADR-8.5). `findFieldFocus`
/// is a wmux addition: focus is in a find field (find-bar Enter forms).
pub const context_keys = [_][]const u8{
    "terminalFocus",              "browserFocus",          "webPanelFocus",
    "markdownFocus",              "markdownEditFocus",     "diffViewerFocus",
    "filePreviewTextEditorFocus", "fileExplorerFocus",     "textBoxFocus",
    "todoFocus",                  "sidebarFocus",          "rightSidebarFocus",
    "commandPaletteVisible",      "findVisible",           "terminalFindVisible",
    "terminalAlternateScreen",    "workspaceCanvasLayout", "panelKind",
    "sidebarMode",                "paneCount",             "workspaceCount",
    "simulatorFocus",             "findFieldFocus",
};

pub const Value = union(enum) {
    boolean: bool,
    int: i64,
    string: []const u8,

    pub fn truthy(v: Value) bool {
        return switch (v) {
            .boolean => |b| b,
            .int => |i| i != 0,
            .string => |s| s.len != 0,
        };
    }
};

/// Read-only view of the context snapshot.
pub const Context = struct {
    ptr: *const anyopaque,
    getFn: *const fn (ptr: *const anyopaque, key: []const u8) ?Value,

    pub fn get(c: Context, key: []const u8) ?Value {
        return c.getFn(c.ptr, key);
    }
};

/// A small array-backed context (tests, palette previews, config doctor).
pub const MapContext = struct {
    pub const Pair = struct { []const u8, Value };
    pairs: []const Pair,

    pub fn context(self: *const MapContext) Context {
        return .{ .ptr = self, .getFn = get };
    }

    fn get(ptr: *const anyopaque, key: []const u8) ?Value {
        const self: *const MapContext = @ptrCast(@alignCast(ptr));
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], key)) return p[1];
        return null;
    }
};

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEnd,
    UnterminatedString,
    InvalidRegex,
    ExpectedKey,
    ExpectedValue,
    InvalidNumber,
    TooDeep,
    OutOfMemory,
};

/// Optional parse diagnostics: byte offset of the failing token.
pub const Diagnostic = struct { offset: usize = 0 };

const max_depth = 64;

const Tag = enum {
    ident,
    string,
    number,
    regex,
    bang,
    and_and,
    or_or,
    lparen,
    rparen,
    lbracket,
    rbracket,
    comma,
    eq,
    ne,
    match,
    lt,
    le,
    gt,
    ge,
    end,
};

const Token = struct {
    tag: Tag,
    start: usize,
    /// Raw text (for strings: between quotes, escapes unprocessed;
    /// for regexes: the pattern; flags in `flags`).
    text: []const u8,
    flags: []const u8 = "",
};

const Lexer = struct {
    src: []const u8,
    pos: usize = 0,

    fn isIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-' or c == ':' or c >= 0x80;
    }

    fn next(lx: *Lexer, regex_ok: bool) ParseError!Token {
        const s = lx.src;
        while (lx.pos < s.len and std.ascii.isWhitespace(s[lx.pos])) lx.pos += 1;
        const start = lx.pos;
        if (start >= s.len) return .{ .tag = .end, .start = start, .text = "" };
        const c = s[start];
        const two: []const u8 = if (start + 1 < s.len) s[start .. start + 2] else s[start..];
        const ops = [_]struct { []const u8, Tag }{
            .{ "&&", .and_and }, .{ "||", .or_or }, .{ "==", .eq }, .{ "!=", .ne },
            .{ "=~", .match },   .{ "<=", .le },    .{ ">=", .ge },
        };
        for (ops) |op| if (std.mem.eql(u8, two, op[0])) {
            lx.pos += 2;
            return .{ .tag = op[1], .start = start, .text = two };
        };
        const single: ?Tag = switch (c) {
            '!' => .bang,
            '(' => .lparen,
            ')' => .rparen,
            '[' => .lbracket,
            ']' => .rbracket,
            ',' => .comma,
            '<' => .lt,
            '>' => .gt,
            else => null,
        };
        if (single) |t| {
            lx.pos += 1;
            return .{ .tag = t, .start = start, .text = s[start..lx.pos] };
        }
        if (c == '\'' or c == '"') {
            var i = start + 1;
            while (i < s.len and s[i] != c) : (i += 1) {
                if (s[i] == '\\') i += 1;
            }
            if (i >= s.len) return error.UnterminatedString;
            lx.pos = i + 1;
            return .{ .tag = .string, .start = start, .text = s[start + 1 .. i] };
        }
        if (c == '/' and regex_ok) {
            var i = start + 1;
            var in_class = false;
            while (i < s.len) : (i += 1) {
                switch (s[i]) {
                    '\\' => i += 1,
                    '[' => in_class = true,
                    ']' => in_class = false,
                    '/' => if (!in_class) break,
                    else => {},
                }
            }
            if (i >= s.len) return error.InvalidRegex;
            var j = i + 1;
            while (j < s.len and std.ascii.isAlphabetic(s[j])) j += 1;
            lx.pos = j;
            return .{ .tag = .regex, .start = start, .text = s[start + 1 .. i], .flags = s[i + 1 .. j] };
        }
        if (std.ascii.isDigit(c) or (c == '-' and start + 1 < s.len and std.ascii.isDigit(s[start + 1]))) {
            var i = start + 1;
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
            if (i < s.len and isIdentChar(s[i]) and s[i] != '-') {
                // "2x" etc.: a bare word, not a number.
                while (i < s.len and isIdentChar(s[i])) i += 1;
                lx.pos = i;
                return .{ .tag = .ident, .start = start, .text = s[start..i] };
            }
            lx.pos = i;
            return .{ .tag = .number, .start = start, .text = s[start..i] };
        }
        if (isIdentChar(c)) {
            var i = start;
            while (i < s.len and isIdentChar(s[i])) i += 1;
            lx.pos = i;
            return .{ .tag = .ident, .start = start, .text = s[start..i] };
        }
        return error.UnexpectedToken;
    }
};

/// Comparison operators.
pub const CmpOp = enum { eq, ne, lt, le, gt, ge };

pub const Node = union(enum) {
    literal: bool,
    key: []const u8,
    not: *const Node,
    @"and": [2]*const Node,
    @"or": [2]*const Node,
    cmp: struct { op: CmpOp, key: []const u8, rhs: Value },
    regex: struct { key: []const u8, pattern: []const u8, icase: bool },
    in_list: struct { key: []const u8, values: []const Value },
};

/// A parsed when-clause. Owns its nodes and strings.
pub const Clause = struct {
    arena: std.heap.ArenaAllocator,
    root: *const Node,

    pub fn deinit(self: *Clause) void {
        self.arena.deinit();
    }

    pub fn eval(self: *const Clause, ctx: Context) bool {
        return evalNode(self.root, ctx);
    }

    /// Appends every context key the clause reads (duplicates possible).
    /// Slices borrow from the clause.
    pub fn collectKeys(self: *const Clause, gpa: std.mem.Allocator, out: *std.ArrayList([]const u8)) error{OutOfMemory}!void {
        try collectNode(self.root, gpa, out);
    }
};

fn collectNode(n: *const Node, gpa: std.mem.Allocator, out: *std.ArrayList([]const u8)) error{OutOfMemory}!void {
    switch (n.*) {
        .literal => {},
        .key => |k| try out.append(gpa, k),
        .not => |inner| try collectNode(inner, gpa, out),
        .@"and", .@"or" => |pair| {
            try collectNode(pair[0], gpa, out);
            try collectNode(pair[1], gpa, out);
        },
        .cmp => |c| try out.append(gpa, c.key),
        .regex => |r| try out.append(gpa, r.key),
        .in_list => |l| try out.append(gpa, l.key),
    }
}

/// True when `key` is one of `context_keys`.
pub fn isContextKey(key: []const u8) bool {
    for (context_keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

/// Parses `src`. The result owns copies of every string it needs.
pub fn parse(gpa: std.mem.Allocator, src: []const u8) ParseError!Clause {
    return parseDiag(gpa, src, null);
}

pub fn parseDiag(gpa: std.mem.Allocator, src: []const u8, diag: ?*Diagnostic) ParseError!Clause {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const owned = try a.dupe(u8, src);
    var p: Parser = .{ .lx = .{ .src = owned }, .a = a };
    const root = p.parseTop() catch |err| {
        if (diag) |d| d.offset = p.err_offset;
        return err;
    };
    return .{ .arena = arena, .root = root };
}

/// Validates a clause without keeping it.
pub fn validate(gpa: std.mem.Allocator, src: []const u8) ParseError!void {
    var c = try parse(gpa, src);
    c.deinit();
}

/// Parses and evaluates in one step (convenience for tests and doctor).
pub fn evalSource(gpa: std.mem.Allocator, src: []const u8, ctx: Context) ParseError!bool {
    var c = try parse(gpa, src);
    defer c.deinit();
    return c.eval(ctx);
}

const Parser = struct {
    lx: Lexer,
    a: std.mem.Allocator,
    peeked: ?Token = null,
    depth: u32 = 0,
    err_offset: usize = 0,

    fn peek(p: *Parser, regex_ok: bool) ParseError!Token {
        if (p.peeked) |t| return t;
        p.err_offset = p.lx.pos;
        const t = try p.lx.next(regex_ok);
        p.peeked = t;
        p.err_offset = t.start;
        return t;
    }

    fn take(p: *Parser, regex_ok: bool) ParseError!Token {
        const t = try p.peek(regex_ok);
        p.peeked = null;
        return t;
    }

    fn fail(p: *Parser, t: Token, err: ParseError) ParseError {
        p.err_offset = t.start;
        return if (t.tag == .end) error.UnexpectedEnd else err;
    }

    fn node(p: *Parser, n: Node) ParseError!*const Node {
        const ptr = try p.a.create(Node);
        ptr.* = n;
        return ptr;
    }

    fn parseTop(p: *Parser) ParseError!*const Node {
        const n = try p.parseBinary(0);
        const t = try p.take(false);
        if (t.tag != .end) return p.fail(t, error.UnexpectedToken);
        return n;
    }

    /// Pratt loop over the infix operators `||` (bp 1) and `&&` (bp 2).
    fn parseBinary(p: *Parser, min_bp: u8) ParseError!*const Node {
        p.depth += 1;
        defer p.depth -= 1;
        if (p.depth > max_depth) return error.TooDeep;
        var lhs = try p.parseUnary();
        while (true) {
            const t = try p.peek(false);
            const bp: u8 = switch (t.tag) {
                .or_or => 1,
                .and_and => 2,
                else => return lhs,
            };
            if (bp <= min_bp) return lhs;
            _ = try p.take(false);
            const rhs = try p.parseBinary(bp);
            lhs = try p.node(if (bp == 1) .{ .@"or" = .{ lhs, rhs } } else .{ .@"and" = .{ lhs, rhs } });
        }
    }

    fn parseUnary(p: *Parser) ParseError!*const Node {
        const t = try p.take(false);
        switch (t.tag) {
            .bang => {
                p.depth += 1;
                defer p.depth -= 1;
                if (p.depth > max_depth) return error.TooDeep;
                return p.node(.{ .not = try p.parseUnary() });
            },
            .lparen => {
                const inner = try p.parseBinary(0);
                const close = try p.take(false);
                if (close.tag != .rparen) return p.fail(close, error.UnexpectedToken);
                return inner;
            },
            .ident => {
                if (std.mem.eql(u8, t.text, "true")) return p.node(.{ .literal = true });
                if (std.mem.eql(u8, t.text, "false")) return p.node(.{ .literal = false });
                return p.parseKeyTail(t.text);
            },
            else => return p.fail(t, error.ExpectedKey),
        }
    }

    fn parseKeyTail(p: *Parser, key: []const u8) ParseError!*const Node {
        const t = try p.peek(false);
        const op: ?CmpOp = switch (t.tag) {
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            else => null,
        };
        if (op) |o| {
            _ = try p.take(false);
            const v = try p.parseValue(try p.take(false));
            return p.node(.{ .cmp = .{ .op = o, .key = key, .rhs = v } });
        }
        if (t.tag == .match) {
            _ = try p.take(false);
            const r = try p.take(true);
            const pattern, const flags = switch (r.tag) {
                .regex => .{ r.text, r.flags },
                .string => .{ try p.unescape(r.text), "" },
                else => return p.fail(r, error.InvalidRegex),
            };
            var icase = false;
            for (flags) |f| switch (f) {
                'i' => icase = true,
                // Other JS flags (g, m, s, u, y) do not change a boolean test.
                'g', 'm', 's', 'u', 'y' => {},
                else => return p.fail(r, error.InvalidRegex),
            };
            if (!regexValid(pattern)) return p.fail(r, error.InvalidRegex);
            return p.node(.{ .regex = .{ .key = key, .pattern = pattern, .icase = icase } });
        }
        if (t.tag == .ident and std.mem.eql(u8, t.text, "in")) {
            _ = try p.take(false);
            const open = try p.take(false);
            if (open.tag != .lbracket) return p.fail(open, error.UnexpectedToken);
            var list: std.ArrayList(Value) = .empty;
            const first = try p.take(false);
            if (first.tag != .rbracket) {
                try list.append(p.a, try p.parseValue(first));
                while (true) {
                    const sep = try p.take(false);
                    if (sep.tag == .rbracket) break;
                    if (sep.tag != .comma) return p.fail(sep, error.UnexpectedToken);
                    try list.append(p.a, try p.parseValue(try p.take(false)));
                }
            }
            return p.node(.{ .in_list = .{ .key = key, .values = list.items } });
        }
        return p.node(.{ .key = key });
    }

    fn parseValue(p: *Parser, t: Token) ParseError!Value {
        return switch (t.tag) {
            .string => .{ .string = try p.unescape(t.text) },
            .number => .{ .int = std.fmt.parseInt(i64, t.text, 10) catch return p.fail(t, error.InvalidNumber) },
            .ident => if (std.mem.eql(u8, t.text, "true"))
                .{ .boolean = true }
            else if (std.mem.eql(u8, t.text, "false"))
                .{ .boolean = false }
            else
                .{ .string = t.text },
            else => p.fail(t, error.ExpectedValue),
        };
    }

    fn unescape(p: *Parser, raw: []const u8) ParseError![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
        var out = try p.a.alloc(u8, raw.len);
        var n: usize = 0;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '\\' and i + 1 < raw.len) i += 1;
            out[n] = raw[i];
            n += 1;
        }
        return out[0..n];
    }
};

fn evalNode(n: *const Node, ctx: Context) bool {
    return switch (n.*) {
        .literal => |b| b,
        .key => |k| if (ctx.get(k)) |v| v.truthy() else false,
        .not => |inner| !evalNode(inner, ctx),
        .@"and" => |pair| evalNode(pair[0], ctx) and evalNode(pair[1], ctx),
        .@"or" => |pair| evalNode(pair[0], ctx) or evalNode(pair[1], ctx),
        .cmp => |c| compare(ctx.get(c.key) orelse .{ .boolean = false }, c.op, c.rhs),
        .regex => |r| blk: {
            const v = ctx.get(r.key) orelse break :blk false;
            var buf: [24]u8 = undefined;
            const text = switch (v) {
                .string => |s| s,
                .int => |i| std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable,
                .boolean => |b| if (b) "true" else "false",
            };
            break :blk regexSearch(r.pattern, text, r.icase);
        },
        .in_list => |l| blk: {
            const v = ctx.get(l.key) orelse break :blk false;
            for (l.values) |item| if (valueEql(v, item)) break :blk true;
            break :blk false;
        },
    };
}

fn valueEql(lhs: Value, rhs: Value) bool {
    return switch (rhs) {
        // `key == true/false` compares truthiness, so `key == false` is `!key`.
        .boolean => |b| lhs.truthy() == b,
        .int => |i| switch (lhs) {
            .int => |l| l == i,
            .string => |s| if (std.fmt.parseInt(i64, s, 10)) |l| l == i else |_| false,
            .boolean => false,
        },
        .string => |s| switch (lhs) {
            .string => |l| std.mem.eql(u8, l, s),
            .int => |l| if (std.fmt.parseInt(i64, s, 10)) |r| l == r else |_| false,
            .boolean => |b| std.mem.eql(u8, s, if (b) "true" else "false"),
        },
    };
}

fn compare(lhs: Value, op: CmpOp, rhs: Value) bool {
    switch (op) {
        .eq => return valueEql(lhs, rhs),
        .ne => return !valueEql(lhs, rhs),
        else => {},
    }
    const l: i64 = switch (lhs) {
        .int => |i| i,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch return false,
        .boolean => return false,
    };
    const r: i64 = switch (rhs) {
        .int => |i| i,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch return false,
        .boolean => return false,
    };
    return switch (op) {
        .lt => l < r,
        .le => l <= r,
        .gt => l > r,
        .ge => l >= r,
        .eq, .ne => unreachable,
    };
}

// ------------------------------------------------------------ mini regex

/// Length of the atom at the start of `pat`, or null when malformed.
fn atomLen(pat: []const u8) ?usize {
    if (pat.len == 0) return null;
    switch (pat[0]) {
        '\\' => return if (pat.len >= 2) 2 else null,
        '[' => {
            var i: usize = 1;
            if (i < pat.len and pat[i] == '^') i += 1;
            if (i < pat.len and pat[i] == ']') i += 1;
            while (i < pat.len) : (i += 1) {
                if (pat[i] == '\\') {
                    i += 1;
                } else if (pat[i] == ']') return i + 1;
            }
            return null;
        },
        '|', '(', ')', '{', '}', '*', '+', '?' => return null,
        else => return 1,
    }
}

fn regexValid(pat: []const u8) bool {
    var i: usize = 0;
    if (i < pat.len and pat[i] == '^') i += 1;
    while (i < pat.len) {
        if (pat[i] == '$' and i + 1 == pat.len) return true;
        if (pat[i] == '^' or pat[i] == '$') return false;
        const n = atomLen(pat[i..]) orelse return false;
        i += n;
        if (i < pat.len and (pat[i] == '*' or pat[i] == '+' or pat[i] == '?')) i += 1;
    }
    return true;
}

fn foldEq(a: u8, b: u8, icase: bool) bool {
    return if (icase) std.ascii.toLower(a) == std.ascii.toLower(b) else a == b;
}

fn escapeMatches(e: u8, c: u8, icase: bool) bool {
    return switch (e) {
        'd' => std.ascii.isDigit(c),
        'D' => !std.ascii.isDigit(c),
        'w' => std.ascii.isAlphanumeric(c) or c == '_',
        'W' => !(std.ascii.isAlphanumeric(c) or c == '_'),
        's' => std.ascii.isWhitespace(c),
        'S' => !std.ascii.isWhitespace(c),
        else => foldEq(e, c, icase),
    };
}

fn classMatches(body: []const u8, c: u8, icase: bool) bool {
    var b = body;
    var negate = false;
    if (b.len > 0 and b[0] == '^') {
        negate = true;
        b = b[1..];
    }
    var hit = false;
    var i: usize = 0;
    while (i < b.len) {
        var lo = b[i];
        var is_escape = false;
        if (lo == '\\' and i + 1 < b.len) {
            is_escape = true;
            i += 1;
            lo = b[i];
        }
        if (!is_escape and i + 2 < b.len and b[i + 1] == '-') {
            const hi = b[i + 2];
            const cl = if (icase) std.ascii.toLower(c) else c;
            const cu = if (icase) std.ascii.toUpper(c) else c;
            if ((c >= lo and c <= hi) or (cl >= lo and cl <= hi) or (cu >= lo and cu <= hi)) hit = true;
            i += 3;
            continue;
        }
        if (if (is_escape) escapeMatches(lo, c, icase) else foldEq(lo, c, icase)) hit = true;
        i += 1;
    }
    return hit != negate;
}

fn atomMatches(atom: []const u8, c: u8, icase: bool) bool {
    return switch (atom[0]) {
        '.' => c != '\n',
        '\\' => escapeMatches(atom[1], c, icase),
        '[' => classMatches(atom[1 .. atom.len - 1], c, icase),
        else => foldEq(atom[0], c, icase),
    };
}

fn matchHere(pat: []const u8, text: []const u8, icase: bool) bool {
    if (pat.len == 0) return true;
    if (pat.len == 1 and pat[0] == '$') return text.len == 0;
    const n = atomLen(pat).?;
    const atom = pat[0..n];
    const q: u8 = if (n < pat.len) pat[n] else 0;
    switch (q) {
        '*', '+', '?' => {
            const rest = pat[n + 1 ..];
            const min: usize = if (q == '+') 1 else 0;
            var count: usize = 0;
            const cap: usize = if (q == '?') 1 else text.len;
            while (count < cap and count < text.len and atomMatches(atom, text[count], icase)) count += 1;
            if (count < min) return false;
            var k = count + 1;
            while (k > min) {
                k -= 1;
                if (matchHere(rest, text[k..], icase)) return true;
            }
            return false;
        },
        else => {
            if (text.len == 0 or !atomMatches(atom, text[0], icase)) return false;
            return matchHere(pat[n..], text[1..], icase);
        },
    }
}

/// Unanchored search (anchors `^`/`$` honored). `pat` must be `regexValid`.
pub fn regexSearch(pat: []const u8, text: []const u8, icase: bool) bool {
    if (pat.len > 0 and pat[0] == '^') return matchHere(pat[1..], text, icase);
    var start: usize = 0;
    while (start <= text.len) : (start += 1) {
        if (matchHere(pat, text[start..], icase)) return true;
    }
    return false;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn ev(src: []const u8, pairs: []const MapContext.Pair) !bool {
    const m: MapContext = .{ .pairs = pairs };
    return evalSource(testing.allocator, src, m.context());
}

test "unit: keys: when-clause boolean truth tables" {
    const bools = [_]bool{ false, true };
    for (bools) |a| for (bools) |b| {
        const ctx = [_]MapContext.Pair{ .{ "a", .{ .boolean = a } }, .{ "b", .{ .boolean = b } } };
        try testing.expectEqual(a and b, try ev("a && b", &ctx));
        try testing.expectEqual(a or b, try ev("a || b", &ctx));
        try testing.expectEqual(!a, try ev("!a", &ctx));
        try testing.expectEqual(a, try ev("!!a", &ctx));
        try testing.expectEqual(!(a and b), try ev("!(a && b)", &ctx));
        try testing.expectEqual(!a and b, try ev("!a && b", &ctx));
        try testing.expectEqual(!a, try ev("a == false", &ctx));
        try testing.expectEqual(a, try ev("a == true", &ctx));
        // The right side of a comparison is a literal: `b` is the string "b".
        try testing.expect(try ev("a != b", &ctx));
        for (bools) |c| {
            const ctx3 = [_]MapContext.Pair{ ctx[0], ctx[1], .{ "c", .{ .boolean = c } } };
            // && binds tighter than ||.
            try testing.expectEqual(a or (b and c), try ev("a || b && c", &ctx3));
            try testing.expectEqual((a and b) or c, try ev("a && b || c", &ctx3));
            try testing.expectEqual((a or b) and c, try ev("(a || b) && c", &ctx3));
        }
    };
    try testing.expect(try ev("true", &.{}));
    try testing.expect(!try ev("false", &.{}));
    try testing.expect(try ev("true || false && false", &.{}));
}

test "unit: keys: when-clause unknown keys read false" {
    try testing.expect(!try ev("nosuchKey", &.{}));
    try testing.expect(try ev("!nosuchKey", &.{}));
    try testing.expect(try ev("nosuchKey == false", &.{}));
    try testing.expect(!try ev("nosuchKey == files", &.{}));
    try testing.expect(try ev("nosuchKey != files", &.{}));
    try testing.expect(!try ev("nosuchKey > 0", &.{}));
    try testing.expect(!try ev("nosuchKey < 1", &.{}));
    try testing.expect(!try ev("nosuchKey =~ /x/", &.{}));
    try testing.expect(!try ev("nosuchKey in [a, b]", &.{}));
}

test "unit: keys: when-clause typed comparisons" {
    const ctx = [_]MapContext.Pair{
        .{ "sidebarMode", .{ .string = "files" } },
        .{ "paneCount", .{ .int = 3 } },
        .{ "workspaceCount", .{ .int = 0 } },
        .{ "panelKind", .{ .string = "markdown" } },
        .{ "terminalFocus", .{ .boolean = true } },
    };
    try testing.expect(try ev("sidebarMode == files", &ctx));
    try testing.expect(try ev("sidebarMode == 'files'", &ctx));
    try testing.expect(try ev("sidebarMode == \"files\"", &ctx));
    try testing.expect(try ev("sidebarMode != feed", &ctx));
    try testing.expect(try ev("sidebarMode", &ctx));
    try testing.expect(try ev("paneCount == 3", &ctx));
    try testing.expect(try ev("paneCount > 1 && paneCount <= 3", &ctx));
    try testing.expect(!try ev("paneCount < 3", &ctx));
    try testing.expect(try ev("paneCount >= 3", &ctx));
    try testing.expect(try ev("paneCount != 2", &ctx));
    try testing.expect(try ev("paneCount > -1", &ctx));
    try testing.expect(!try ev("workspaceCount", &ctx));
    try testing.expect(try ev("workspaceCount == false", &ctx));
    try testing.expect(try ev("paneCount == true", &ctx));
    try testing.expect(!try ev("sidebarMode > 1", &ctx));
    try testing.expect(try ev("sidebarMode in [files, find]", &ctx));
    try testing.expect(try ev("sidebarMode in ['sessions', 'files']", &ctx));
    try testing.expect(!try ev("sidebarMode in [feed, dock]", &ctx));
    try testing.expect(!try ev("sidebarMode in []", &ctx));
    try testing.expect(try ev("paneCount in [1, 2, 3]", &ctx));
    try testing.expect(try ev("terminalFocus && paneCount > 1 || false", &ctx));
    // `!` applies to the whole comparison: !(terminalFocus == false).
    try testing.expect(try ev("!terminalFocus == false", &ctx));
    try testing.expect(try ev("panelKind =~ /^mark/", &ctx));
    try testing.expect(try ev("panelKind =~ /DOWN$/i", &ctx));
    try testing.expect(!try ev("panelKind =~ /DOWN$/", &ctx));
    try testing.expect(try ev("panelKind =~ 'k.o'", &ctx));
    try testing.expect(try ev("paneCount =~ /^[0-9]+$/", &ctx));
}

test "unit: keys: when-clause unicode strings" {
    const ctx = [_]MapContext.Pair{.{ "panelKind", .{ .string = "f\u{00FC}r-\u{65E5}\u{672C}" } }};
    try testing.expect(try ev("panelKind == 'f\u{00FC}r-\u{65E5}\u{672C}'", &ctx));
    try testing.expect(try ev("panelKind =~ /\u{65E5}/", &ctx));
    try testing.expect(try ev("panelKind == f\u{00FC}r-\u{65E5}\u{672C}", &ctx));
    try testing.expect(try ev("panelKind != 'it\\'s'", &ctx));
}

test "unit: keys: when-clause malformed input is rejected" {
    const a = testing.allocator;
    const cases = [_]struct { []const u8, ParseError }{
        .{ "", error.UnexpectedEnd },
        .{ "   ", error.UnexpectedEnd },
        .{ "a &&", error.UnexpectedEnd },
        .{ "&& a", error.ExpectedKey },
        .{ "(a", error.UnexpectedEnd },
        .{ "a)", error.UnexpectedToken },
        .{ "a b", error.UnexpectedToken },
        .{ "a == ", error.UnexpectedEnd },
        .{ "a == (", error.ExpectedValue },
        .{ "a == 'x", error.UnterminatedString },
        .{ "a =~ /x", error.InvalidRegex },
        .{ "a =~ /(x)/", error.InvalidRegex },
        .{ "a =~ /x|y/", error.InvalidRegex },
        .{ "a =~ /*x/", error.InvalidRegex },
        .{ "a =~ /[ab/", error.InvalidRegex },
        .{ "a =~ /x/q", error.InvalidRegex },
        .{ "a =~ x", error.InvalidRegex },
        .{ "a in b", error.UnexpectedToken },
        .{ "a in [b", error.UnexpectedEnd },
        .{ "a in [b c]", error.UnexpectedToken },
        .{ "a == 99999999999999999999", error.InvalidNumber },
        .{ "a & b", error.UnexpectedToken },
        .{ "a | b", error.UnexpectedToken },
        .{ "a = b", error.UnexpectedToken },
        .{ "#", error.UnexpectedToken },
    };
    for (cases) |c| {
        const got = validate(a, c[0]);
        testing.expectError(c[1], got) catch |err| {
            std.log.err("clause '{s}'", .{c[0]});
            return err;
        };
    }
    var d: Diagnostic = .{};
    try testing.expectError(error.UnexpectedToken, parseDiag(a, "aa && bb cc", &d));
    try testing.expectEqual(@as(usize, 9), d.offset);
}

test "unit: keys: when-clause nesting is bounded" {
    const a = testing.allocator;
    const deep = "(" ** 200 ++ "a" ++ ")" ** 200;
    try testing.expectError(error.TooDeep, validate(a, deep));
    const bangs = "!" ** 500 ++ "a";
    try testing.expectError(error.TooDeep, validate(a, bangs));
    const ok = "(" ** 20 ++ "a" ++ ")" ** 20;
    try validate(a, ok);
    // A long flat chain is fine (left-associative loop, not recursion).
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try aw.writer.writeAll("k0");
    for (1..2000) |i| try aw.writer.print(" && k{d} || !k{d}", .{ i, i });
    try testing.expect(try ev(aw.written(), &.{}));
}

test "unit: keys: mini regex" {
    try testing.expect(regexValid("^a.c*d+e?[x-z]\\.$"));
    try testing.expect(regexSearch("b+", "abbbc", false));
    try testing.expect(regexSearch("^ab*c$", "ac", false));
    try testing.expect(!regexSearch("^ab+c$", "ac", false));
    try testing.expect(regexSearch("a?b", "b", false));
    try testing.expect(regexSearch("[^0-9]", "12a", false));
    try testing.expect(!regexSearch("[^0-9]", "123", false));
    try testing.expect(regexSearch("\\d\\d", "a12", false));
    try testing.expect(regexSearch("[A-Z]", "q", true));
    try testing.expect(regexSearch("", "", false));
    try testing.expect(regexSearch("x*", "", false));
    try testing.expect(!regexSearch("^$", "a", false));
    try testing.expect(regexSearch("a.*z", "a" ++ "m" ** 5000 ++ "z", false));
}

test "unit: keys: when-clause key collection" {
    const a = testing.allocator;
    var c = try parse(a, "!terminalFocus && (sidebarMode in [files] || paneCount > 1 || panelKind =~ /x/) || true");
    defer c.deinit();
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(a);
    try c.collectKeys(a, &keys);
    try testing.expectEqual(@as(usize, 4), keys.items.len);
    for (keys.items) |k| try testing.expect(isContextKey(k));
    try testing.expect(!isContextKey("nope"));
}
