//! The site's table of contents, as a table.
//!
//! One row per page, in reading order, the way `standard_modules` in
//! `src/luce/01_source/load.zig` is one row per std module.  Adding a
//! page is: the Markdown file, one row here.  Nothing scans a
//! directory, so the order of the site is a thing someone decided
//! rather than a thing the filesystem happened to produce.
//!
//! Five sections form the documentation's main paths; Status records the
//! boundary around them:
//!
//!   Learn     — "How do I start and build a working mental model?"
//!   Guides    — "How do I reason about a whole theme?"
//!   Reference — "What exactly does this syntax mean?"
//!   Library   — "What can the standard modules do?"
//!   Status    — "What is implemented today?"
//!
//! The URL slugs describe the current pre-release information architecture.
//! Labels and ordering are part of the reading experience; changing them is
//! cheap before the first public release, but should still be deliberate.

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
        .slug = "learn",
        .label = "Learn",
        .title = "Learn Luce",
        .blurb = "A guided path from your first program to modules, ownership, failure handling and the outside world.",
        .pages = &.{
            .{ .slug = "hello", .title = "Hello, Luce", .blurb = "Build the toolchain, compile a program, run it." },
            .{ .slug = "values", .title = "Values and types", .blurb = "Numbers, strings, enums and function values, plus the one-way numeric promotion rules." },
            .{ .slug = "control", .title = "Control flow", .blurb = "if, elif, else, while, for, and the two shapes the parser refuses to guess at." },
            .{ .slug = "functions", .title = "Functions and structs", .blurb = "func, parameters, returns, function values, capture-free lambdas, and value structs." },
            .{ .slug = "enums", .title = "Enums", .blurb = "A name for every number that is secretly a set, and the match that checks you covered them." },
            .{ .slug = "collections", .title = "Lists, maps and arrays", .blurb = "The four heap objects, their methods, and how you walk them." },
            .{ .slug = "constants", .title = "Constants and shared tables", .blurb = "File-scope const, map literals, program-root identity, and the immutable boundary." },
            .{ .slug = "strings", .title = "Strings", .blurb = "Immutable UTF-8, f-strings, slicing, and where the rest of the string library lives." },
            .{ .slug = "ownership", .title = "Memory and ownership", .blurb = "Scope ownership: no collector, no reference counting, and four words to learn." },
            .{ .slug = "absence", .title = "Absence", .blurb = "T?, none, narrowing, and else — saying that a thing might not be there." },
            .{ .slug = "unions", .title = "Unions", .blurb = "One of a few shapes, each carrying its own fields — and match, the only door to the payload." },
            .{ .slug = "failure", .title = "Failure", .blurb = "T!, try, catch and error — and the rule that decides between a trap and an error." },
            .{ .slug = "modules", .title = "Modules", .blurb = "A file is a module; the standard library lives under std." },
            .{ .slug = "visibility", .title = "Visibility", .blurb = "Public until it says private — the marker, the struct regions, and the factory pattern." },
            .{ .slug = "host", .title = "The outside world", .blurb = "Printing, arguments, files, and the terminal — every effect is a host service." },
            .{ .slug = "threads", .title = "Workers", .blurb = "spawn runs a function on a worker with a world of its own, and the ownership rules you already know are the concurrency rules." },
            .{ .slug = "next", .title = "Where to go next", .blurb = "What you have seen, what you have not, and where each of them is written down." },
        },
    },
    .{
        .slug = "guides",
        .label = "Guides",
        .title = "Guides",
        .blurb = "Task-oriented explanations for the parts of Luce that need more than a syntax entry.",
        .pages = &.{
            .{ .slug = "structures", .title = "Structures: keep data and invariants together", .blurb = "Choose fields and methods, preserve invariants, and decide when a struct should own an object." },
            .{ .slug = "unions", .title = "Unions: make alternatives explicit", .blurb = "Model several valid shapes, match them safely, and keep payload ownership explicit." },
            .{ .slug = "memory", .title = "Memory without a collector", .blurb = "Why scope ownership, what it costs, and how it compares to the alternatives that were refused." },
            .{ .slug = "failure", .title = "Traps are bugs, errors are news", .blurb = "The one rule that decides whether a failure is a trap, an error, or an absence." },
            .{ .slug = "strings", .title = "Strings and copies", .blurb = "Immutable UTF-8 values with an owner, small-string optimisation, and the one benchmark still behind." },
            .{ .slug = "organization", .title = "Organize a project and make a package", .blurb = "Author in the source tree, then promote the package to an installed dependency." },
            .{ .slug = "performance", .title = "Performance", .blurb = "The benchmark table against C twins, what it measures, and what it does not." },
            .{ .slug = "toolchain", .title = "Build and run Luce programs", .blurb = "luce, standalone executables, loadable artifacts, and the two build modes." },
            .{ .slug = "testing", .title = "Testing", .blurb = "luce test: a test is a func test_* in an ordinary file, and there is no framework." },
            .{ .slug = "first-program", .title = "Hello and arguments", .blurb = "The smallest complete program, and reading the command line." },
            .{ .slug = "loops", .title = "Loops and ranges", .blurb = "range, for over a collection, enumerate, while, break and continue." },
            .{ .slug = "lists", .title = "Lists", .blurb = "Building, comparator sorting, searching, and slicing in a complete program." },
            .{ .slug = "maps", .title = "Maps", .blurb = "Insertion-ordered dictionaries with O(1) lookup in a complete program." },
            .{ .slug = "arrays", .title = "Arrays and grids", .blurb = "Fixed-shape numeric storage, up to four dimensions." },
            .{ .slug = "text", .title = "Text processing", .blurb = "Splitting, joining, trimming, and counting with std.strings." },
            .{ .slug = "structs", .title = "Structs", .blurb = "Value aggregates, implied-self methods, static functions, and structs that carry objects." },
            .{ .slug = "ownership-example", .title = "give, copy and free", .blurb = "The four situations where memory needs a word from you." },
            .{ .slug = "optionals", .title = "Optionals", .blurb = "parse_int, none, narrowing, and the else fallback." },
            .{ .slug = "errors", .title = "Errors", .blurb = "A fallible function, try, catch, and an uncaught error's one-line report." },
            .{ .slug = "traps", .title = "Traps", .blurb = "What a bug looks like: a stable code, a line, and a call trace." },
            .{ .slug = "files", .title = "Files", .blurb = "Reading and writing through std.files, with the failure handled." },
            .{ .slug = "programs", .title = "The bundled programs", .blurb = "Real userland programs, included from source and exercised by the site." },
        },
    },
    .{
        .slug = "reference",
        .label = "Reference",
        .title = "The Luce reference",
        .blurb = "The exact rules: syntax, types, statements, expressions, ownership, modules, builtins and failure.",
        .pages = &.{
            .{ .slug = "lexical", .title = "Source text and lexical elements", .blurb = "Encoding, indentation, comments, literals, keywords, operators." },
            .{ .slug = "types", .title = "Types", .blurb = "Values, function signatures, heap objects, optionals, and the type of every expression." },
            .{ .slug = "expressions", .title = "Expressions", .blurb = "Operators, precedence, direct and indirect calls, lambdas, indexing, slicing, and the two refused shapes." },
            .{ .slug = "statements", .title = "Statements and declarations", .blurb = "let, var, assignment, control flow, func, struct, and file-scope constants." },
            .{ .slug = "ownership", .title = "Ownership", .blurb = "The ratified memory model, S1 to S46, each one addressable on its own." },
            .{ .slug = "failure", .title = "Traps and errors", .blurb = "Every trap code, both error codes, and what each one means." },
            .{ .slug = "modules", .title = "Modules", .blurb = "Imports, the std namespace, and the three rules that keep it honest." },
            .{ .slug = "builtins", .title = "Builtins", .blurb = "Every free function and every method, with its signature." },
        },
    },
    .{
        .slug = "library",
        .label = "Library",
        .title = "Standard library",
        .blurb = "The modules that ship with the compiler, with signatures, examples and the limits of each API.",
        .pages = &.{
            .{ .slug = "math", .title = "std.math", .blurb = "Transcendentals, integer powers, whole-array reductions, and a seeded generator." },
            .{ .slug = "strings", .title = "std.strings", .blurb = "Everything built on the String primitives: find, split, join, trim, case, padding." },
            .{ .slug = "files", .title = "std.files", .blurb = "A thin, fallible layer over the host's file services." },
            .{ .slug = "lists", .title = "std.lists", .blurb = "Stable comparator sorting for every list element type, with named functions or capture-free lambdas." },
            .{ .slug = "paths", .title = "std.paths", .blurb = "Pure text over path names: join, base, dir, extension, stem." },
            .{ .slug = "os", .title = "std.os", .blurb = "The machine's own facts: how much memory it has, how much is left, how many processors." },
            .{ .slug = "term", .title = "std.term", .blurb = "Terminal drawing and keyboard, mouse, and resize events." },
            .{ .slug = "zip", .title = "std.zip", .blurb = "ZIP archives and DEFLATE, in pure Luce: read a real archive, write one, and check it." },
            .{ .slug = "json", .title = "std.json", .blurb = "JSON against RFC 8259, as a union: match a value, build one, write it back." },
            .{ .slug = "gpu", .title = "std.gpu", .blurb = "Backend-neutral surfaces for low-level drawing, with Metal and Vulkan kept behind the host boundary." },
            .{ .slug = "ui", .title = "std.ui", .blurb = "Windows and their drawing surfaces, before a higher-level UI package exists." },
        },
    },
    .{
        .slug = "status",
        .label = "Status",
        .title = "Where Luce stands",
        .blurb = "A dated, concrete account of what works, what is missing and what is deliberately out of scope.",
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
