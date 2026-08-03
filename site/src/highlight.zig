//! Luce syntax highlighting, as a scanner over source bytes.
//!
//! Deliberately not the compiler's lexer: the site must render a
//! *deliberately broken* sample (the ownership errors, the precedence
//! refusals) exactly as well as a correct one, and it must never fail.
//! So this is a forgiving scanner that classifies bytes and never
//! rejects any.  The word tables below are copied from the language,
//! and `test "the keyword table matches the language's"` in this file
//! is what keeps them honest.
//!
//! Classes, and the CSS they reach:
//!
//!   c  comment          k  keyword         t  type name
//!   s  string literal   v  ownership verb  b  builtin
//!   n  number literal   d  declared name

const std = @import("std");
const Buffer = @import("buffer.zig");

/// Reserved words that read as control or declaration.
const keywords = [_][]const u8{
    "func",     "struct", "let", "var",   "if",     "elif",
    "else",     "while",  "for", "in",    "return", "break",
    "continue", "and",    "or",  "not",   "true",   "false",
    "import",   "none",   "try", "catch",
};

/// The words that move ownership.  They get a class of their own
/// because they are the language's one genuinely unusual idea, and a
/// reader scanning a page should be able to see every one of them.
const verbs = [_][]const u8{ "give", "copy", "free", "new" };

/// Type names the language itself spells.  Any other capitalised
/// identifier is highlighted as a type too — that is the convention
/// the language enforces for structs.
const type_names = [_][]const u8{
    "Bool", "Int", "Float", "String",  "Bytes",
    "List", "Map", "Array", "Builder",
};

/// The free builtins, plus the host-gated ones.  `docs/LANGUAGE.md`
/// "Conversions and generic builtins" is the source.
const builtins = [_][]const u8{
    "len",         "str",        "print",       "range",     "assert",
    "trap",        "error",      "abs",         "min",       "max",
    "clamp",       "sqrt",       "floor",       "ceil",      "chr",
    "ord",         "parse_int",  "parse_float", "file_read", "file_write",
    "file_exists", "arg",        "arg_count",   "key_read",  "key_text",
    "term_rows",   "term_cols",  "term_clear",  "term_move", "term_style",
    "term_write",  "term_flush",
};

fn inTable(table: []const []const u8, word: []const u8) bool {
    for (table) |entry| {
        if (std.mem.eql(u8, entry, word)) return true;
    }
    return false;
}

fn isWordByte(byte: u8) bool {
    return byte == '_' or std.ascii.isAlphanumeric(byte);
}

fn isWordStart(byte: u8) bool {
    return byte == '_' or std.ascii.isAlphabetic(byte);
}

/// Write `source` into `out` as escaped HTML with `<span>` classes.
pub fn render(out: *Buffer, source: []const u8) !void {
    var index: usize = 0;
    // The last word seen, so `func name` and `struct Name` can mark the
    // name they declare.  Reset by anything that is not a word.
    var previous_word: []const u8 = "";

    while (index < source.len) {
        const byte = source[index];

        if (byte == '#') {
            const start = index;
            while (index < source.len and source[index] != '\n') index += 1;
            try span(out, "c", source[start..index]);
            previous_word = "";
            continue;
        }

        // An f-string is one token: the `f` belongs to the literal.
        if (byte == 'f' and index + 1 < source.len and source[index + 1] == '"' and
            (index == 0 or !isWordByte(source[index - 1])))
        {
            index = try string(out, source, index, index + 1);
            previous_word = "";
            continue;
        }

        if (byte == '"') {
            index = try string(out, source, index, index);
            previous_word = "";
            continue;
        }

        if (std.ascii.isDigit(byte)) {
            const start = index;
            while (index < source.len and (std.ascii.isDigit(source[index]) or
                source[index] == '.' or source[index] == 'e' or source[index] == 'E' or
                ((source[index] == '+' or source[index] == '-') and index > start and
                    (source[index - 1] == 'e' or source[index - 1] == 'E')))) index += 1;
            try span(out, "n", source[start..index]);
            previous_word = "";
            continue;
        }

        if (isWordStart(byte)) {
            const start = index;
            while (index < source.len and isWordByte(source[index])) index += 1;
            const word = source[start..index];

            const class: ?[]const u8 = blk: {
                if (std.mem.eql(u8, previous_word, "func")) break :blk "d";
                if (std.mem.eql(u8, previous_word, "struct")) break :blk "t";
                if (inTable(&verbs, word)) break :blk "v";
                if (inTable(&keywords, word)) break :blk "k";
                if (inTable(&type_names, word)) break :blk "t";
                if (std.ascii.isUpper(word[0])) break :blk "t";
                if (inTable(&builtins, word)) break :blk "b";
                break :blk null;
            };
            if (class) |name| try span(out, name, word) else try out.addEscaped(word);
            previous_word = word;
            continue;
        }

        // Anything else — operators, punctuation, whitespace.  Only a
        // space keeps the previous word in view, so `func` two lines up
        // cannot mark an unrelated name.
        if (byte != ' ') previous_word = "";
        try out.addEscaped(source[index .. index + 1]);
        index += 1;
    }
}

/// Emit a string literal starting at `open` (the quote), with the token
/// itself beginning at `start` (one earlier for an f-string).  Returns
/// the index just past the literal.  An unterminated literal runs to
/// the end of its line, which is what the lexer reports too.
fn string(out: *Buffer, source: []const u8, start: usize, open: usize) !usize {
    var index = open + 1;
    while (index < source.len and source[index] != '"' and source[index] != '\n') {
        if (source[index] == '\\' and index + 1 < source.len) index += 1;
        index += 1;
    }
    if (index < source.len and source[index] == '"') index += 1;
    try span(out, "s", source[start..index]);
    return index;
}

fn span(out: *Buffer, class: []const u8, chunk: []const u8) !void {
    try out.print("<span class=\"{s}\">", .{class});
    try out.addEscaped(chunk);
    try out.add("</span>");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn highlighted(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: Buffer = .init(gpa);
    errdefer out.deinit();
    try render(&out, source);
    return out.take();
}

test "keywords, verbs, types, builtins and declared names each get their class" {
    const gpa = std.testing.allocator;
    const html = try highlighted(gpa, "func total(xs: give List(Int)) -> Int:\n    return len(xs)");
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"k\">func</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"d\">total</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"v\">give</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"t\">List</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"b\">len</span>") != null);
}

test "comments, strings, f-strings and numbers are one token each" {
    const gpa = std.testing.allocator;
    const html = try highlighted(gpa, "# note\nlet x = f\"a{b}\" # tail\nlet y = 1.5e-3");
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"c\"># note</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"s\">f&quot;a{b}&quot;</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"n\">1.5e-3</span>") != null);
}

test "every byte of the input survives highlighting" {
    const gpa = std.testing.allocator;
    const source =
        \\struct Bag:
        \\    items: List(Int)
        \\
        \\func main():
        \\    var bag = Bag(items = [1, 2])   # <&>
        \\    print(str(len(bag.items)))
    ;
    const html = try highlighted(gpa, source);
    defer gpa.free(html);

    // Strip tags and unescape; what is left must be the original.
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(gpa);
    var index: usize = 0;
    while (index < html.len) {
        if (html[index] == '<') {
            while (index < html.len and html[index] != '>') index += 1;
            index += 1;
        } else if (std.mem.startsWith(u8, html[index..], "&amp;")) {
            try plain.append(gpa, '&');
            index += 5;
        } else if (std.mem.startsWith(u8, html[index..], "&lt;")) {
            try plain.append(gpa, '<');
            index += 4;
        } else if (std.mem.startsWith(u8, html[index..], "&gt;")) {
            try plain.append(gpa, '>');
            index += 4;
        } else if (std.mem.startsWith(u8, html[index..], "&quot;")) {
            try plain.append(gpa, '"');
            index += 6;
        } else if (std.mem.startsWith(u8, html[index..], "&#39;")) {
            try plain.append(gpa, '\'');
            index += 5;
        } else {
            try plain.append(gpa, html[index]);
            index += 1;
        }
    }
    try std.testing.expectEqualStrings(source, plain.items);
}

test "the word tables agree with the language" {
    // Every keyword the lexer reserves is either a keyword or a verb
    // here, and nothing appears in both tables.
    const reserved = [_][]const u8{
        "func",  "struct", "let",  "var",    "if",    "elif",     "else",
        "while", "for",    "in",   "return", "break", "continue", "and",
        "or",    "not",    "true", "false",  "new",   "import",   "give",
        "copy",  "none",   "try",  "catch",
    };
    for (reserved) |word| {
        const as_keyword = inTable(&keywords, word);
        const as_verb = inTable(&verbs, word);
        try std.testing.expect(as_keyword or as_verb);
        try std.testing.expect(!(as_keyword and as_verb));
    }
}
