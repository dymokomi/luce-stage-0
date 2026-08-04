//! Luce syntax highlighting, as a scanner over source bytes.
//!
//! Deliberately not the compiler's lexer: the site must render a
//! *deliberately broken* sample (the ownership errors, the precedence
//! refusals) exactly as well as a correct one, and it must never fail.
//! So this is a forgiving scanner that classifies bytes and never
//! rejects any.
//!
//! **The word tables below are copied from the language**, and
//! `test "every name the language spells has a class here"` is what
//! keeps them honest.  Copied and not imported: the compiler's tables
//! live inside the `luce` module, and this generator links nothing —
//! it drives the built binaries as subprocesses (site/build.sh), which
//! is what lets it verify what the toolchain really does.  The test is
//! the whole guard, so it checks every table.  The two that had one
//! were the two that stayed correct; `builtins` had none and drifted
//! nine names behind the language.
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
    "Bool", "Int", "Float", "String",
    "List", "Map", "Array", "Builder",
};

/// Everything callable by name on its own: the free builtins, the
/// host-gated ones, and `range`.  The compiler's list is the table in
/// `04_semantics/builder.zig`'s `lowerIntrinsic`, less `free`, which
/// is a verb above.
const builtins = [_][]const u8{
    "abs",         "min",         "max",         "clamp",       "sqrt",
    "floor",       "ceil",        "len",         "range",       "assert",
    "trap",        "error",       "str",         "parse_int",   "parse_float",
    "chr",         "ord",         "print",       "print_error", "read_line",
    "env",         "clock_ms",    "sleep_ms",    "file_read",   "file_write",
    "file_append", "file_exists", "file_delete", "file_rename", "dir_list",
    "arg",         "arg_count",   "term_rows",   "term_cols",   "term_clear",
    "term_move",   "term_style",  "term_write",  "term_flush",  "key_read",
    "key_text",
};

/// Names that mean something only behind a receiver: `xs.append(v)`,
/// `m.has(k)`, `s.byte_at(0)`.  They get the builtin class, but only
/// after a `.` — several of them (`find`, `get`, `clear`, `values`)
/// are words a program may perfectly well use for its own function,
/// and colouring one of those as language would be a lie about it.
///
/// The compiler's lists are `list_methods`, `array_methods`,
/// `map_methods` and `builder_methods` in `04_semantics/builder.zig`,
/// plus the two String primitives beside them.
const methods = [_][]const u8{
    "byte_at", "find_byte", "append", "append_ascii", "insert",
    "remove",  "pop",       "clear",  "sort",         "reverse",
    "find",    "contains",  "dim",    "fill",         "has",
    "get",     "keys",      "values",
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
    // Whether the byte just before this one was a `.`, which is what
    // tells a method from an ordinary name of the same spelling.
    var after_dot = false;

    while (index < source.len) {
        const byte = source[index];

        if (byte == '#') {
            const start = index;
            while (index < source.len and source[index] != '\n') index += 1;
            try span(out, "c", source[start..index]);
            previous_word = "";
            after_dot = false;
            continue;
        }

        // An f-string is one token: the `f` belongs to the literal.
        if (byte == 'f' and index + 1 < source.len and source[index + 1] == '"' and
            (index == 0 or !isWordByte(source[index - 1])))
        {
            index = try string(out, source, index, index + 1);
            previous_word = "";
            after_dot = false;
            continue;
        }

        if (byte == '"') {
            index = try string(out, source, index, index);
            previous_word = "";
            after_dot = false;
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
            after_dot = false;
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
                if (after_dot and inTable(&methods, word)) break :blk "b";
                break :blk null;
            };
            if (class) |name| try span(out, name, word) else try out.addEscaped(word);
            previous_word = word;
            after_dot = false;
            continue;
        }

        // Anything else — operators, punctuation, whitespace.  Only a
        // space keeps the previous word in view, so `func` two lines up
        // cannot mark an unrelated name.
        if (byte != ' ') previous_word = "";
        after_dot = byte == '.';
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

test "a method reads as language only behind its receiver" {
    const gpa = std.testing.allocator;
    const html = try highlighted(gpa, "let a = xs.find(1)\nlet b = find(1)");
    defer gpa.free(html);
    // `xs.find(...)` is the language's method.
    try std.testing.expect(std.mem.indexOf(u8, html, ".<span class=\"b\">find</span>") != null);
    // A bare `find` is somebody's own function and is left alone.
    try std.testing.expect(std.mem.indexOf(u8, html, "= find(") != null);
}

test "every name the language spells has a class here" {
    // This is the whole guard on the tables above, so it covers all
    // four of them.  `keywords`/`verbs` had a check like this and
    // stayed correct; `builtins` had none and fell nine names behind.
    //
    // The lists below are copied from the compiler — the generator
    // links nothing, so they cannot be imported (see this file's
    // header).  What the test proves is that the copies are complete
    // and that no name is filed under two classes at once.

    // `02_lex/lexer.zig`: what the lexer reserves as a word token.
    const lexed = [_][]const u8{
        "func",  "struct", "let",  "var",    "if",    "elif",     "else",
        "while", "for",    "in",   "return", "break", "continue", "and",
        "or",    "not",    "true", "false",  "new",   "import",   "give",
        "copy",  "none",   "try",  "catch",
    };
    for (lexed) |word| {
        const as_keyword = inTable(&keywords, word);
        const as_verb = inTable(&verbs, word);
        try std.testing.expect(as_keyword or as_verb);
        try std.testing.expect(!(as_keyword and as_verb));
    }

    // `04_semantics/declarations.zig`'s `reserved_names`: everything
    // the language keeps for itself, which no program may redeclare
    // and every one of which may therefore appear in a sample.
    const reserved = [_][]const u8{
        "range",      "Int",         "Float",       "Bool",        "String",
        "List",       "Map",         "Array",       "Builder",     "None",
        "abs",        "min",         "max",         "clamp",       "sqrt",
        "floor",      "ceil",        "len",         "byte_at",     "assert",
        "trap",       "str",         "parse_int",   "parse_float", "chr",
        "ord",        "append",      "pop",         "insert",      "remove",
        "has",        "dim",         "free",        "print",       "file_read",
        "file_write", "file_exists", "arg",         "arg_count",   "key_read",
        "key_text",   "error",       "read_line",   "print_error", "clock_ms",
        "sleep_ms",   "env",         "file_append", "file_delete", "file_rename",
        "dir_list",   "term_rows",   "term_cols",   "term_clear",  "term_move",
        "term_style", "term_write",  "term_flush",
    };
    // The receiver methods `reserved_names` does not carry: a program
    // *may* declare these, because they are resolved by receiver type
    // and so collide with nothing — but where a program does not, they
    // are the language and must read as it.  Sources are the four
    // method tables in `04_semantics/builder.zig`, plus `find_byte`
    // beside them.  The `term_*` services moved out of this list and
    // into the one above when the language reserved them.
    const also = [_][]const u8{
        "find_byte",    "clear", "sort", "reverse", "find",
        "contains",     "fill",  "get",  "keys",    "values",
        "append_ascii",
    };

    for (&[_][]const []const u8{ &reserved, &also }) |list| {
        for (list) |word| {
            var classes: usize = 0;
            if (inTable(&keywords, word)) classes += 1;
            if (inTable(&verbs, word)) classes += 1;
            if (inTable(&type_names, word)) classes += 1;
            if (inTable(&builtins, word)) classes += 1;
            if (inTable(&methods, word)) classes += 1;
            // A capitalised name the tables do not spell is still a
            // type: that is the rule `render` applies to any struct a
            // sample declares, and `None` reaches it that way.
            if (classes == 0 and std.ascii.isUpper(word[0])) continue;
            if (classes != 1) {
                std.debug.print("'{s}' has {d} classes, want 1\n", .{ word, classes });
                return error.TestUnexpectedResult;
            }
        }
    }

    // And nothing in the tables is spelled twice across them.
    const tables = [_][]const []const u8{ &keywords, &verbs, &type_names, &builtins, &methods };
    for (tables, 0..) |table, position| {
        for (table) |word| {
            for (tables[position + 1 ..]) |other| {
                if (inTable(other, word)) {
                    std.debug.print("'{s}' is in two tables\n", .{word});
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}
