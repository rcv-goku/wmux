//! JSONC reader (comments, trailing commas) for cmux.json and wmux.json
//! (ADR-5.3). `parse` builds a tree whose nodes keep their byte spans in the
//! source, so validators can report `line:col` and `json_edit.zig` can splice
//! the original text losslessly. The `Tokenizer` never allocates and also
//! runs at comptime (spec defaults are checked with `isValidLiteral`).

const std = @import("std");

pub const default_max_depth: u32 = 128;

/// 1-based line and column. Columns count Unicode code points, so a message
/// points at the same character an editor shows.
pub const Pos = struct {
    line: u32,
    col: u32,

    pub fn format(self: Pos, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}:{d}", .{ self.line, self.col });
    }
};

/// Line and column of byte `offset` in `src` (clamped to `src.len`).
pub fn position(src: []const u8, offset: usize) Pos {
    const end = @min(offset, src.len);
    var line: u32 = 1;
    var col: u32 = 1;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        const c = src[i];
        if (c == '\n') {
            line += 1;
            col = 1;
        } else if (c & 0xC0 != 0x80) {
            // Count lead bytes only: one column per code point.
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

/// The first syntax error of a parse. `message` is a static string.
pub const Diagnostic = struct {
    offset: usize = 0,
    pos: Pos = .{ .line = 1, .col = 1 },
    message: []const u8 = "",

    pub fn format(self: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}:{d}: {s}", .{ self.pos.line, self.pos.col, self.message });
    }
};

pub const Options = struct {
    allow_comments: bool = true,
    allow_trailing_commas: bool = true,
    max_depth: u32 = default_max_depth,
};

pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,

    pub const Tag = enum {
        lbrace,
        rbrace,
        lbracket,
        rbracket,
        colon,
        comma,
        string,
        number,
        true,
        false,
        null,
        eof,
    };
};

pub const TokenError = struct {
    offset: usize,
    message: []const u8,
};

/// Splits JSONC into tokens, skipping whitespace and comments. A leading
/// UTF-8 byte order mark is skipped. On error `next` returns null and sets
/// `err`.
pub const Tokenizer = struct {
    src: []const u8,
    i: usize = 0,
    allow_comments: bool = true,
    err: ?TokenError = null,

    pub fn init(src: []const u8, allow_comments: bool) Tokenizer {
        const bom = "\xEF\xBB\xBF";
        const start: usize = if (std.mem.startsWith(u8, src, bom)) bom.len else 0;
        return .{ .src = src, .i = start, .allow_comments = allow_comments };
    }

    fn fail(self: *Tokenizer, offset: usize, message: []const u8) ?Token {
        self.err = .{ .offset = offset, .message = message };
        return null;
    }

    pub fn next(self: *Tokenizer) ?Token {
        const src = self.src;
        if (self.allow_comments) {
            const r = skipTrivia(src, self.i);
            if (r.unterminated_comment) return self.fail(r.end, "unterminated comment");
            self.i = r.end;
        } else {
            while (self.i < src.len and isWhitespace(src[self.i])) self.i += 1;
            if (self.i + 1 < src.len and src[self.i] == '/' and (src[self.i + 1] == '/' or src[self.i + 1] == '*'))
                return self.fail(self.i, "comments are not allowed");
        }
        const start = self.i;
        if (start >= src.len) return .{ .tag = .eof, .start = start, .end = start };
        const c = src[start];
        const single: ?Token.Tag = switch (c) {
            '{' => .lbrace,
            '}' => .rbrace,
            '[' => .lbracket,
            ']' => .rbracket,
            ':' => .colon,
            ',' => .comma,
            else => null,
        };
        if (single) |tag| {
            self.i += 1;
            return .{ .tag = tag, .start = start, .end = start + 1 };
        }
        switch (c) {
            '"' => {
                switch (scanString(src, start)) {
                    .err => |e| return self.fail(e.offset, e.message),
                    .end => |end| {
                        self.i = end;
                        return .{ .tag = .string, .start = start, .end = end };
                    },
                }
            },
            '-', '0'...'9' => {
                const end = scanNumber(src, start) orelse return self.fail(start, "invalid number");
                self.i = end;
                return .{ .tag = .number, .start = start, .end = end };
            },
            't', 'f', 'n' => {
                const words = [_]struct { []const u8, Token.Tag }{
                    .{ "true", .true }, .{ "false", .false }, .{ "null", .null },
                };
                for (words) |wd| {
                    if (std.mem.startsWith(u8, src[start..], wd[0]) and
                        (start + wd[0].len == src.len or !isIdentChar(src[start + wd[0].len])))
                    {
                        self.i = start + wd[0].len;
                        return .{ .tag = wd[1], .start = start, .end = self.i };
                    }
                }
                return self.fail(start, "unexpected character");
            },
            else => return self.fail(start, "unexpected character"),
        }
    }
};

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 0x80;
}

pub const TriviaResult = struct {
    end: usize,
    unterminated_comment: bool = false,
};

/// Skips whitespace, `//` line comments and `/* */` block comments from `i`.
pub fn skipTrivia(src: []const u8, start: usize) TriviaResult {
    var i = start;
    while (i < src.len) {
        const c = src[i];
        if (isWhitespace(c)) {
            i += 1;
        } else if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            i += 2;
            while (i < src.len and src[i] != '\n') i += 1;
        } else if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, src, i + 2, "*/") orelse
                return .{ .end = i, .unterminated_comment = true };
            i = close + 2;
        } else break;
    }
    return .{ .end = i };
}

/// Skips spaces, tabs and comments that end on the current line. Stops at
/// the line break (`\n` or `\r\n`, not consumed) or at the first other byte.
pub fn skipTriviaSameLine(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len) {
        const c = src[i];
        if (c == '\r' and i + 1 < src.len and src[i + 1] == '\n') break;
        if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
        } else if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') i += 1;
            if (i > start and src[i - 1] == '\r') i -= 1;
            break;
        } else if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, src, i + 2, "*/") orelse return i;
            if (std.mem.indexOfScalar(u8, src[i..close], '\n') != null) return i;
            i = close + 2;
        } else break;
    }
    return i;
}

/// Byte offset of the start of the line containing `offset`.
pub fn lineStart(src: []const u8, offset: usize) usize {
    var i = @min(offset, src.len);
    while (i > 0 and src[i - 1] != '\n') i -= 1;
    return i;
}

/// The leading spaces and tabs of the line containing `offset`.
pub fn lineIndent(src: []const u8, offset: usize) []const u8 {
    const s = lineStart(src, offset);
    var e = s;
    while (e < src.len and (src[e] == ' ' or src[e] == '\t')) e += 1;
    return src[s..e];
}

/// True when `src[i..]` starts with a line break (`\n` or `\r\n`).
pub fn isLineBreakAt(src: []const u8, i: usize) bool {
    if (i < src.len and src[i] == '\n') return true;
    return i + 1 < src.len and src[i] == '\r' and src[i + 1] == '\n';
}

/// True when only spaces and tabs precede `offset` on its line.
pub fn isFirstOnLine(src: []const u8, offset: usize) bool {
    const s = lineStart(src, offset);
    for (src[s..offset]) |c| if (c != ' ' and c != '\t') return false;
    return true;
}

const ScanError = struct { offset: usize, message: []const u8 };

const StringScan = union(enum) { end: usize, err: ScanError };

/// Scans the string literal starting at the quote at `start`.
fn scanString(src: []const u8, start: usize) StringScan {
    var i = start + 1;
    while (i < src.len) {
        const c = src[i];
        switch (c) {
            '"' => return .{ .end = i + 1 },
            '\\' => {
                if (i + 1 >= src.len) return .{ .err = .{ .offset = i, .message = "unterminated string" } };
                switch (src[i + 1]) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => i += 2,
                    'u' => {
                        if (i + 6 > src.len) return .{ .err = .{ .offset = i, .message = "invalid escape sequence" } };
                        for (src[i + 2 .. i + 6]) |h| {
                            if (!std.ascii.isHex(h)) return .{ .err = .{ .offset = i, .message = "invalid escape sequence" } };
                        }
                        i += 6;
                    },
                    else => return .{ .err = .{ .offset = i, .message = "invalid escape sequence" } },
                }
            },
            0...0x1F => return .{ .err = .{
                .offset = i,
                .message = if (c == '\n') "unterminated string" else "control character in string",
            } },
            0x20...0x21, 0x23...0x5B, 0x5D...0x7F => i += 1,
            else => {
                const n = std.unicode.utf8ByteSequenceLength(c) catch
                    return .{ .err = .{ .offset = i, .message = "invalid UTF-8" } };
                if (i + n > src.len) return .{ .err = .{ .offset = i, .message = "invalid UTF-8" } };
                _ = std.unicode.utf8Decode(src[i .. i + n]) catch
                    return .{ .err = .{ .offset = i, .message = "invalid UTF-8" } };
                i += n;
            },
        }
    }
    return .{ .err = .{ .offset = start, .message = "unterminated string" } };
}

fn scanNumber(src: []const u8, start: usize) ?usize {
    var i = start;
    if (src[i] == '-') i += 1;
    if (i >= src.len) return null;
    if (src[i] == '0') {
        i += 1;
    } else if (src[i] >= '1' and src[i] <= '9') {
        while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
    } else return null;
    if (i < src.len and src[i] == '.') {
        i += 1;
        const d = i;
        while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
        if (i == d) return null;
    }
    if (i < src.len and (src[i] == 'e' or src[i] == 'E')) {
        i += 1;
        if (i < src.len and (src[i] == '+' or src[i] == '-')) i += 1;
        const d = i;
        while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
        if (i == d) return null;
    }
    if (i < src.len and isIdentChar(src[i])) return null;
    return i;
}

/// Non-allocating check that `src` is exactly one JSONC value (comments and
/// trailing commas allowed). Usable at comptime.
pub fn isValidLiteral(src: []const u8) bool {
    var t = Tokenizer.init(src, true);
    var stack: [default_max_depth]u8 = undefined;
    var depth: usize = 0;
    // States: 0 expect value, 1 after value, 2 expect key (or close), 3 expect colon.
    var state: u8 = 0;
    var done = false;
    while (true) {
        const tok = t.next() orelse return false;
        if (done) return tok.tag == .eof;
        switch (state) {
            0 => switch (tok.tag) {
                .lbrace, .lbracket => {
                    if (depth == stack.len) return false;
                    stack[depth] = if (tok.tag == .lbrace) '{' else '[';
                    depth += 1;
                    state = if (tok.tag == .lbrace) 2 else 0;
                },
                .rbracket => {
                    // Empty array or trailing comma.
                    if (depth == 0 or stack[depth - 1] != '[') return false;
                    depth -= 1;
                    state = 1;
                },
                .string, .number, .true, .false, .null => state = 1,
                else => return false,
            },
            1 => {
                if (depth == 0) {
                    done = true;
                    if (tok.tag != .eof) return false;
                    return true;
                }
                const open = stack[depth - 1];
                switch (tok.tag) {
                    .comma => state = if (open == '{') 2 else 0,
                    .rbrace => {
                        if (open != '{') return false;
                        depth -= 1;
                    },
                    .rbracket => {
                        if (open != '[') return false;
                        depth -= 1;
                    },
                    else => return false,
                }
            },
            2 => switch (tok.tag) {
                .string => state = 3,
                .rbrace => {
                    depth -= 1;
                    state = 1;
                },
                else => return false,
            },
            3 => {
                if (tok.tag != .colon) return false;
                state = 0;
            },
            else => unreachable,
        }
        if (state == 1 and depth == 0) done = true;
    }
}

pub const Node = struct {
    /// Byte span of the value in the parsed source.
    start: usize,
    end: usize,
    data: Data,

    pub const Data = union(enum) {
        null,
        boolean: bool,
        /// Raw number text as written (validated JSON number syntax).
        number: []const u8,
        /// Decoded string contents.
        string: []const u8,
        array: []const Node,
        object: []const Member,
    };

    pub fn kindName(self: *const Node) []const u8 {
        return switch (self.data) {
            .null => "null",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .array => "array",
            .object => "object",
        };
    }

    /// The member named `key` (the last one when a key repeats, matching
    /// `std.json`'s last-wins rule).
    pub fn getMember(self: *const Node, key: []const u8) ?*const Member {
        const members = switch (self.data) {
            .object => |m| m,
            else => return null,
        };
        var i = members.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, members[i].key, key)) return &members[i];
        }
        return null;
    }

    pub fn get(self: *const Node, key: []const u8) ?*const Node {
        const m = self.getMember(key) orelse return null;
        return &m.value;
    }

    /// Follows `segments` through nested objects.
    pub fn getPath(self: *const Node, segments: []const []const u8) ?*const Node {
        var cur = self;
        for (segments) |seg| cur = cur.get(seg) orelse return null;
        return cur;
    }

    /// Follows a dotted path such as `sidebar.showPorts`.
    pub fn getDotted(self: *const Node, path: []const u8) ?*const Node {
        var cur = self;
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |seg| cur = cur.get(seg) orelse return null;
        return cur;
    }

    pub fn asInt(self: *const Node) ?i64 {
        const raw = switch (self.data) {
            .number => |n| n,
            else => return null,
        };
        return std.fmt.parseInt(i64, raw, 10) catch null;
    }

    pub fn asFloat(self: *const Node) ?f64 {
        const raw = switch (self.data) {
            .number => |n| n,
            else => return null,
        };
        return std.fmt.parseFloat(f64, raw) catch null;
    }

    pub fn asBool(self: *const Node) ?bool {
        return switch (self.data) {
            .boolean => |b| b,
            else => null,
        };
    }

    pub fn asString(self: *const Node) ?[]const u8 {
        return switch (self.data) {
            .string => |s| s,
            else => null,
        };
    }

    /// Streams the value through a `std.json.Stringify`, so the caller picks
    /// minified or indented output. Numbers keep their source spelling.
    pub fn write(self: *const Node, jw: *std.json.Stringify) std.Io.Writer.Error!void {
        switch (self.data) {
            .null => try jw.write(null),
            .boolean => |b| try jw.write(b),
            .number => |n| try jw.print("{s}", .{n}),
            .string => |s| try jw.write(s),
            .array => |items| {
                try jw.beginArray();
                for (items) |*item| try item.write(jw);
                try jw.endArray();
            },
            .object => |members| {
                try jw.beginObject();
                for (members) |*m| {
                    try jw.objectField(m.key);
                    try m.value.write(jw);
                }
                try jw.endObject();
            },
        }
    }

    /// Minified canonical JSON text of the value (comments dropped).
    pub fn toJsonAlloc(self: *const Node, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        self.write(&jw) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    /// Structural equality (object member order matters; numbers compare by
    /// value when both parse as f64).
    pub fn eql(a: *const Node, b: *const Node) bool {
        if (std.meta.activeTag(a.data) != std.meta.activeTag(b.data)) return false;
        return switch (a.data) {
            .null => true,
            .boolean => |x| x == b.data.boolean,
            .number => |x| std.mem.eql(u8, x, b.data.number) or
                (if (a.asFloat()) |fa| (if (b.asFloat()) |fb| fa == fb else false) else false),
            .string => |x| std.mem.eql(u8, x, b.data.string),
            .array => |x| blk: {
                const y = b.data.array;
                if (x.len != y.len) break :blk false;
                for (x, y) |*p, *q| if (!p.eql(q)) break :blk false;
                break :blk true;
            },
            .object => |x| blk: {
                const y = b.data.object;
                if (x.len != y.len) break :blk false;
                for (x, y) |*p, *q| {
                    if (!std.mem.eql(u8, p.key, q.key) or !p.value.eql(&q.value)) break :blk false;
                }
                break :blk true;
            },
        };
    }
};

pub const Member = struct {
    key: []const u8,
    /// Byte span of the quoted key.
    key_start: usize,
    key_end: usize,
    value: Node,
};

/// A parsed JSONC document. All nodes and decoded strings live in `arena`;
/// `src` is borrowed and must outlive the document.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    src: []const u8,
    root: Node,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn posOf(self: *const Document, offset: usize) Pos {
        return position(self.src, offset);
    }
};

pub const ParseError = error{ OutOfMemory, SyntaxError };

/// Parses one JSONC value. On `error.SyntaxError`, `diag` (when given) holds
/// the first error with its position.
pub fn parse(gpa: std.mem.Allocator, src: []const u8, opts: Options, diag: ?*Diagnostic) ParseError!Document {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const root = try parseInto(arena.allocator(), src, opts, diag);
    return .{ .arena = arena, .src = src, .root = root };
}

/// Like `parse`, but allocates nodes in a caller-owned (arena) allocator.
pub fn parseInto(arena: std.mem.Allocator, src: []const u8, opts: Options, diag: ?*Diagnostic) ParseError!Node {
    var p: Parser = .{
        .arena = arena,
        .src = src,
        .tok = Tokenizer.init(src, opts.allow_comments),
        .opts = opts,
        .diag = diag,
    };
    const first = try p.advance();
    if (first.tag == .eof) return p.fail(first.start, "unexpected end of input");
    const root = try p.parseValue(first, 0);
    const last = try p.advance();
    if (last.tag != .eof) return p.fail(last.start, "unexpected content after the root value");
    return root;
}

const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    tok: Tokenizer,
    opts: Options,
    diag: ?*Diagnostic,

    fn fail(self: *Parser, offset: usize, message: []const u8) ParseError {
        if (self.diag) |d| d.* = .{ .offset = offset, .pos = position(self.src, offset), .message = message };
        return error.SyntaxError;
    }

    fn advance(self: *Parser) ParseError!Token {
        return self.tok.next() orelse {
            const e = self.tok.err.?;
            return self.fail(e.offset, e.message);
        };
    }

    fn parseValue(self: *Parser, t: Token, depth: u32) ParseError!Node {
        switch (t.tag) {
            .null => return .{ .start = t.start, .end = t.end, .data = .null },
            .true => return .{ .start = t.start, .end = t.end, .data = .{ .boolean = true } },
            .false => return .{ .start = t.start, .end = t.end, .data = .{ .boolean = false } },
            .number => return .{ .start = t.start, .end = t.end, .data = .{ .number = self.src[t.start..t.end] } },
            .string => return .{ .start = t.start, .end = t.end, .data = .{ .string = try self.decodeString(t) } },
            .lbrace => return self.parseObject(t, depth + 1),
            .lbracket => return self.parseArray(t, depth + 1),
            .eof => return self.fail(t.start, "unexpected end of input"),
            else => return self.fail(t.start, "expected a value"),
        }
    }

    fn parseArray(self: *Parser, open: Token, depth: u32) ParseError!Node {
        if (depth > self.opts.max_depth) return self.fail(open.start, "nesting too deep");
        var items: std.ArrayList(Node) = .empty;
        var t = try self.advance();
        while (true) {
            if (t.tag == .rbracket) break;
            try items.append(self.arena, try self.parseValue(t, depth));
            t = try self.advance();
            if (t.tag == .comma) {
                const comma = t;
                t = try self.advance();
                if (t.tag == .rbracket and !self.opts.allow_trailing_commas)
                    return self.fail(comma.start, "trailing comma");
                continue;
            }
            if (t.tag == .rbracket) break;
            if (t.tag == .eof) return self.fail(t.start, "unexpected end of input");
            return self.fail(t.start, "expected ',' or ']'");
        }
        return .{ .start = open.start, .end = t.end, .data = .{ .array = try items.toOwnedSlice(self.arena) } };
    }

    fn parseObject(self: *Parser, open: Token, depth: u32) ParseError!Node {
        if (depth > self.opts.max_depth) return self.fail(open.start, "nesting too deep");
        var members: std.ArrayList(Member) = .empty;
        var t = try self.advance();
        while (true) {
            if (t.tag == .rbrace) break;
            if (t.tag == .eof) return self.fail(t.start, "unexpected end of input");
            if (t.tag != .string) return self.fail(t.start, "expected a string key");
            const key = try self.decodeString(t);
            const colon = try self.advance();
            if (colon.tag != .colon) return self.fail(colon.start, "expected ':'");
            const vt = try self.advance();
            const value = try self.parseValue(vt, depth);
            try members.append(self.arena, .{ .key = key, .key_start = t.start, .key_end = t.end, .value = value });
            t = try self.advance();
            if (t.tag == .comma) {
                const comma = t;
                t = try self.advance();
                if (t.tag == .rbrace and !self.opts.allow_trailing_commas)
                    return self.fail(comma.start, "trailing comma");
                continue;
            }
            if (t.tag == .rbrace) break;
            if (t.tag == .eof) return self.fail(t.start, "unexpected end of input");
            return self.fail(t.start, "expected ',' or '}'");
        }
        return .{ .start = open.start, .end = t.end, .data = .{ .object = try members.toOwnedSlice(self.arena) } };
    }

    fn decodeString(self: *Parser, t: Token) ParseError![]const u8 {
        const body = self.src[t.start + 1 .. t.end - 1];
        if (std.mem.indexOfScalar(u8, body, '\\') == null) return body;
        var out: std.ArrayList(u8) = .empty;
        try out.ensureTotalCapacity(self.arena, body.len);
        var i: usize = 0;
        while (i < body.len) {
            const c = body[i];
            if (c != '\\') {
                out.appendAssumeCapacity(c);
                i += 1;
                continue;
            }
            const e = body[i + 1];
            const simple: ?u8 = switch (e) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'b' => 0x08,
                'f' => 0x0C,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => null,
            };
            if (simple) |s| {
                out.appendAssumeCapacity(s);
                i += 2;
                continue;
            }
            // \uXXXX, possibly a surrogate pair.
            const at = t.start + 1 + i;
            var cp: u21 = std.fmt.parseInt(u16, body[i + 2 .. i + 6], 16) catch unreachable;
            i += 6;
            if (cp >= 0xD800 and cp <= 0xDBFF) {
                if (i + 6 > body.len or body[i] != '\\' or body[i + 1] != 'u')
                    return self.fail(at, "invalid unicode escape");
                const lo = std.fmt.parseInt(u16, body[i + 2 .. i + 6], 16) catch
                    return self.fail(at, "invalid unicode escape");
                if (lo < 0xDC00 or lo > 0xDFFF) return self.fail(at, "invalid unicode escape");
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                i += 6;
            } else if (cp >= 0xDC00 and cp <= 0xDFFF) {
                return self.fail(at, "invalid unicode escape");
            }
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
            try out.appendSlice(self.arena, buf[0..n]);
        }
        return out.toOwnedSlice(self.arena);
    }
};

const testing = std.testing;

fn expectSyntaxError(src: []const u8, opts: Options, line: u32, col: u32, message: []const u8) !void {
    var diag: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, parse(testing.allocator, src, opts, &diag));
    try testing.expectEqualStrings(message, diag.message);
    try testing.expectEqual(line, diag.pos.line);
    try testing.expectEqual(col, diag.pos.col);
}

test "unit: proto: jsonc parses comments and trailing commas" {
    const src =
        \\// leading comment
        \\{
        \\  /* block */ "a": 1, // trailing
        \\  "b": [true, false, null,],
        \\  "c": {"d": "x",},
        \\}
    ;
    var doc = try parse(testing.allocator, src, .{}, null);
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 1), doc.root.get("a").?.asInt().?);
    try testing.expectEqual(@as(usize, 3), doc.root.get("b").?.data.array.len);
    try testing.expectEqualStrings("x", doc.root.getDotted("c.d").?.asString().?);
    try testing.expect(doc.root.getDotted("c.e") == null);
    try testing.expect(doc.root.getDotted("a.b") == null);
}

test "unit: proto: jsonc spans point at the source text" {
    const src = "{ \"key\" : [1, 2] }";
    var doc = try parse(testing.allocator, src, .{}, null);
    defer doc.deinit();
    const m = doc.root.getMember("key").?;
    try testing.expectEqualStrings("\"key\"", src[m.key_start..m.key_end]);
    try testing.expectEqualStrings("[1, 2]", src[m.value.start..m.value.end]);
    try testing.expectEqual(@as(usize, 0), doc.root.start);
    try testing.expectEqual(src.len, doc.root.end);
}

test "unit: proto: jsonc strict mode rejects comments and trailing commas" {
    const strict: Options = .{ .allow_comments = false, .allow_trailing_commas = false };
    try expectSyntaxError("{\"a\": 1 // x\n}", strict, 1, 9, "comments are not allowed");
    try expectSyntaxError("{\"a\": 1,}", strict, 1, 8, "trailing comma");
    try expectSyntaxError("[1,]", strict, 1, 3, "trailing comma");
}

test "unit: proto: jsonc errors carry line and column" {
    try expectSyntaxError("{\n  \"a\": 1\n  \"b\": 2\n}", .{}, 3, 3, "expected ',' or '}'");
    try expectSyntaxError("{\n  \"a\" 1\n}", .{}, 2, 7, "expected ':'");
    try expectSyntaxError("{\"a\": }", .{}, 1, 7, "expected a value");
    try expectSyntaxError("{\"a\": 1", .{}, 1, 8, "unexpected end of input");
    try expectSyntaxError("", .{}, 1, 1, "unexpected end of input");
    try expectSyntaxError("  // only a comment\n", .{}, 2, 1, "unexpected end of input");
    try expectSyntaxError("{} {}", .{}, 1, 4, "unexpected content after the root value");
    try expectSyntaxError("{\"a\": tru}", .{}, 1, 7, "unexpected character");
    try expectSyntaxError("{\"a\": 01}", .{}, 1, 7, "invalid number");
    try expectSyntaxError("{\"a\": 1.}", .{}, 1, 7, "invalid number");
    try expectSyntaxError("{\"a\": \"x\n\"}", .{}, 1, 9, "unterminated string");
    try expectSyntaxError("{\"a\": \"\\q\"}", .{}, 1, 8, "invalid escape sequence");
    try expectSyntaxError("{\"a\": \"\\ud800\"}", .{}, 1, 8, "invalid unicode escape");
    try expectSyntaxError("{\"a\": \"\xff\"}", .{}, 1, 8, "invalid UTF-8");
    try expectSyntaxError("{ /* open", .{}, 1, 3, "unterminated comment");
    try expectSyntaxError("{1: 2}", .{}, 1, 2, "expected a string key");
    try expectSyntaxError("[1 2]", .{}, 1, 4, "expected ',' or ']'");
    try expectSyntaxError("{,}", .{}, 1, 2, "expected a string key");
}

test "unit: proto: jsonc columns count code points" {
    // "é" and "日" are multi-byte; the error column counts characters.
    try expectSyntaxError("{\"é日\": x}", .{}, 1, 8, "unexpected character");
    try testing.expectEqual(Pos{ .line = 2, .col = 3 }, position("a\r\nbc", 5));
}

test "unit: proto: jsonc decodes escapes and unicode" {
    const src = "{\"s\": \"a\\n\\t\\\"\\u00e9\\ud83d\\ude00/\\/\", \"u\": \"日本\"}";
    var doc = try parse(testing.allocator, src, .{}, null);
    defer doc.deinit();
    try testing.expectEqualStrings("a\n\t\"é😀//", doc.root.get("s").?.asString().?);
    try testing.expectEqualStrings("日本", doc.root.get("u").?.asString().?);
}

test "unit: proto: jsonc skips a byte order mark" {
    var doc = try parse(testing.allocator, "\xEF\xBB\xBF{\"a\": true}", .{}, null);
    defer doc.deinit();
    try testing.expectEqual(true, doc.root.get("a").?.asBool().?);
}

test "unit: proto: jsonc duplicate keys resolve to the last one" {
    var doc = try parse(testing.allocator, "{\"a\": 1, \"a\": 2}", .{}, null);
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 2), doc.root.get("a").?.asInt().?);
}

test "unit: proto: jsonc nesting depth is bounded" {
    const deep = "[" ** 200 ++ "]" ** 200;
    try expectSyntaxError(deep, .{}, 1, 129, "nesting too deep");
    var doc = try parse(testing.allocator, deep, .{ .max_depth = 256 }, null);
    doc.deinit();
}

test "unit: proto: jsonc handles a huge document" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\n");
    for (0..5000) |i| try aw.writer.print("  \"k{d}\": [{d}, \"v\", {{\"n\": null}}], // c\n", .{ i, i });
    try aw.writer.writeAll("}\n");
    var doc = try parse(testing.allocator, aw.written(), .{}, null);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 5000), doc.root.data.object.len);
    try testing.expectEqual(@as(i64, 4999), doc.root.get("k4999").?.data.array[0].asInt().?);
}

test "unit: proto: jsonc canonical output drops comments" {
    var doc = try parse(testing.allocator, "{ \"a\" : [1.50, \"é\"], /* x */ \"b\": {} }", .{}, null);
    defer doc.deinit();
    const out = try doc.root.toJsonAlloc(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"a\":[1.50,\"é\"],\"b\":{}}", out);
}

test "unit: proto: jsonc node equality" {
    var a = try parse(testing.allocator, "{\"x\": [1, 2.0, \"s\"]}", .{}, null);
    defer a.deinit();
    var b = try parse(testing.allocator, "{\"x\":[1,2,\"s\"]} // c", .{}, null);
    defer b.deinit();
    var c = try parse(testing.allocator, "{\"x\":[1,2,\"t\"]}", .{}, null);
    defer c.deinit();
    try testing.expect(a.root.eql(&b.root));
    try testing.expect(!a.root.eql(&c.root));
}

test "unit: proto: jsonc isValidLiteral works at comptime" {
    comptime {
        std.debug.assert(isValidLiteral("true"));
        std.debug.assert(isValidLiteral("[\"a\", \"b\",]"));
        std.debug.assert(isValidLiteral("{\"a\": {\"b\": [1, {}]}}"));
        std.debug.assert(!isValidLiteral("[1,,]"));
        std.debug.assert(!isValidLiteral("{\"a\"}"));
        std.debug.assert(!isValidLiteral(""));
        std.debug.assert(!isValidLiteral("1 2"));
        std.debug.assert(!isValidLiteral("[}"));
    }
    try testing.expect(isValidLiteral("{} // trailing comment"));
    try testing.expect(!isValidLiteral("{\"a\": 1"));
}
