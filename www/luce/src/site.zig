//! The site's table of contents, as a table.
//!
//! One row per page, in reading order, the way `standard_modules` in
//! `src/luce/01_source/load.zig` is one row per std module.  Adding a
//! page is: the Markdown file, one row here.  Nothing scans a
//! directory, so the order of the site is a thing someone decided
//! rather than a thing the filesystem happened to produce.
//!
//! The six sections follow the split every good language site
//! converges on — a linear tour for someone new, short complete
//! programs for someone browsing, essays for someone who already
//! writes the language, a normative reference for someone
//! implementing against it, the library, and an honest account of
//! where the thing actually stands.

pub const Page = struct {
    /// Both the source path under `content/` and the URL path.
    slug: []const u8,
    title: []const u8,
    /// One line, shown in section indexes and search results.
    blurb: []const u8,
};

pub const Section = struct {
    slug: []const u8,
    /// The word in the header bar.
    label: []const u8,
    /// The heading of the section's own index page.
    title: []const u8,
    blurb: []const u8,
    pages: []const Page,
};

pub const sections = [_]Section{
    .{
        .slug = "tour",
        .label = "Tour",
        .title = "A tour of Luce",
        .blurb = "Start here. Fifteen short chapters, in order, from installing the compiler to writing a program that reads a file.",
        .pages = &.{
            .{ .slug = "hello", .title = "Hello, Luce", .blurb = "Build the toolchain, compile a program, run it." },
            .{ .slug = "values", .title = "Values and types", .blurb = "Int, Float, Bool, String, and the rule that there are no implicit conversions." },
            .{ .slug = "control", .title = "Control flow", .blurb = "if, elif, else, while, for, and the two shapes the parser refuses to guess at." },
            .{ .slug = "functions", .title = "Functions and structs", .blurb = "func, parameters, returns, and value structs with namespaced functions." },
            .{ .slug = "enums", .title = "Enums", .blurb = "A name for every number that is secretly a set, and the match that checks you covered them." },
            .{ .slug = "collections", .title = "Lists, maps and arrays", .blurb = "The four heap objects, their methods, and how you walk them." },
            .{ .slug = "strings", .title = "Strings", .blurb = "Immutable UTF-8, f-strings, slicing, and where the rest of the string library lives." },
            .{ .slug = "ownership", .title = "Memory", .blurb = "Scope ownership: no collector, no reference counting, and four words to learn." },
            .{ .slug = "absence", .title = "Absence", .blurb = "T?, none, narrowing, and else — saying that a thing might not be there." },
            .{ .slug = "failure", .title = "Failure", .blurb = "T!, try, catch and error — and the rule that decides between a trap and an error." },
            .{ .slug = "modules", .title = "Modules", .blurb = "A file is a module; the standard library lives under std." },
            .{ .slug = "visibility", .title = "Visibility", .blurb = "Public until it says private — the marker, the struct regions, and the factory pattern." },
            .{ .slug = "host", .title = "The outside world", .blurb = "Printing, arguments, files, and the terminal — every effect is a host service." },
            .{ .slug = "threads", .title = "Workers", .blurb = "spawn runs a function on a worker with a world of its own, and the ownership rules you already know are the concurrency rules." },
            .{ .slug = "next", .title = "Where to go next", .blurb = "What you have seen, what you have not, and where each of them is written down." },
        },
    },
    .{
        .slug = "examples",
        .label = "Examples",
        .title = "Luce by example",
        .blurb = "Complete programs, each one compiled and run to produce the output printed beneath it. Read them in any order.",
        .pages = &.{
            .{ .slug = "hello", .title = "Hello and arguments", .blurb = "The smallest program, and reading the command line." },
            .{ .slug = "loops", .title = "Loops and ranges", .blurb = "range, for over a collection, enumerate, while, break and continue." },
            .{ .slug = "lists", .title = "Lists", .blurb = "Building, sorting, searching, slicing." },
            .{ .slug = "maps", .title = "Maps", .blurb = "Insertion-ordered dictionaries with O(1) lookup." },
            .{ .slug = "arrays", .title = "Arrays and grids", .blurb = "Fixed-shape numeric storage, up to four dimensions." },
            .{ .slug = "text", .title = "Text processing", .blurb = "Splitting, joining, trimming and counting with std.strings." },
            .{ .slug = "structs", .title = "Structs", .blurb = "Value aggregates, namespaced functions, and structs that carry objects." },
            .{ .slug = "ownership", .title = "give, copy and free", .blurb = "The four situations where memory needs a word from you." },
            .{ .slug = "optionals", .title = "Optionals", .blurb = "parse_int, none, narrowing, and the else fallback." },
            .{ .slug = "errors", .title = "Errors", .blurb = "A fallible function, try, catch, and an uncaught error's one-line report." },
            .{ .slug = "traps", .title = "Traps", .blurb = "What a bug looks like: a stable code, a line, and a call trace." },
            .{ .slug = "files", .title = "Files", .blurb = "Reading and writing through std.files, with the failure handled." },
            .{ .slug = "programs", .title = "The bundled programs", .blurb = "The real userland in the repository, compiled and run from its own source." },
        },
    },
    .{
        .slug = "guide",
        .label = "Guides",
        .title = "Effective Luce",
        .blurb = "Longer pieces on the parts of the language that are unusual, and on what the measurements actually say.",
        .pages = &.{
            .{ .slug = "memory", .title = "Memory without a collector", .blurb = "Why scope ownership, what it costs, and how it compares to the alternatives that were refused." },
            .{ .slug = "failure", .title = "Traps are bugs, errors are news", .blurb = "The one rule that decides whether a failure is a trap, an error, or an absence." },
            .{ .slug = "strings", .title = "Strings and copies", .blurb = "Immutable UTF-8 values with an owner, small-string optimisation, and the one benchmark still behind." },
            .{ .slug = "performance", .title = "Performance", .blurb = "The benchmark table against C twins, what it measures, and what it does not." },
            .{ .slug = "toolchain", .title = "The compiler and the terminal", .blurb = "luce, loom, the three artifacts, the one engine, and the two build modes." },
        },
    },
    .{
        .slug = "ref",
        .label = "Reference",
        .title = "The Luce reference",
        .blurb = "Normative. What the compiler in this repository accepts and what it means. Terse on purpose; the tour is where the explanations are.",
        .pages = &.{
            .{ .slug = "lexical", .title = "Source text and lexical elements", .blurb = "Encoding, indentation, comments, literals, keywords, operators." },
            .{ .slug = "types", .title = "Types", .blurb = "Values, heap objects, optionals, and the type of every expression." },
            .{ .slug = "expressions", .title = "Expressions", .blurb = "Operators, precedence, calls, indexing, slicing, and the two refused shapes." },
            .{ .slug = "statements", .title = "Statements and declarations", .blurb = "let, var, assignment, control flow, func, struct, and file-scope constants." },
            .{ .slug = "ownership", .title = "Ownership", .blurb = "The ratified memory model, S1 to S43, each one addressable on its own." },
            .{ .slug = "failure", .title = "Traps and errors", .blurb = "Every trap code, both error codes, and what each one means." },
            .{ .slug = "modules", .title = "Modules", .blurb = "Imports, the std namespace, and the three rules that keep it honest." },
            .{ .slug = "builtins", .title = "Builtins", .blurb = "Every free function and every method, with its signature." },
        },
    },
    .{
        .slug = "std",
        .label = "Library",
        .title = "The standard library",
        .blurb = "Seven modules, written in ordinary Luce and embedded in the compiler. There is no install path and there is no package manager.",
        .pages = &.{
            .{ .slug = "math", .title = "std.math", .blurb = "Transcendentals, integer powers, whole-array reductions, and a seeded generator." },
            .{ .slug = "strings", .title = "std.strings", .blurb = "Everything built on the String primitives: find, split, join, trim, case, padding." },
            .{ .slug = "files", .title = "std.files", .blurb = "A thin, fallible layer over the host's file services." },
            .{ .slug = "paths", .title = "std.paths", .blurb = "Pure text over path names: join, base, dir, extension, stem." },
            .{ .slug = "os", .title = "std.os", .blurb = "The machine's own facts: how much memory it has, how much is left, how many processors." },
            .{ .slug = "zip", .title = "std.zip", .blurb = "ZIP archives and DEFLATE, in pure Luce: read a real archive, write one, and check it." },
            .{ .slug = "json", .title = "std.json", .blurb = "JSON against RFC 8259, parsed lazily into a flat document: read the leaves, print it back." },
        },
    },
    .{
        .slug = "status",
        .label = "Status",
        .title = "Where Luce stands",
        .blurb = "What works, what is measured, and what is missing. Written from the repository's own inventory rather than from hope.",
        .pages = &.{},
    },
};

test "every slug is unique within its section, and every section is unique" {
    const std = @import("std");
    for (sections, 0..) |section, index| {
        try std.testing.expect(section.slug.len > 0);
        try std.testing.expect(section.pages.len < 40);
        for (sections[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, section.slug, other.slug));
            try std.testing.expect(!std.mem.eql(u8, section.label, other.label));
        }
        for (section.pages, 0..) |page, position| {
            try std.testing.expect(page.slug.len > 0);
            try std.testing.expect(page.blurb.len > 0);
            for (section.pages[position + 1 ..]) |sibling| {
                try std.testing.expect(!std.mem.eql(u8, page.slug, sibling.slug));
            }
        }
    }
}
