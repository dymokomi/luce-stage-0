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
//!   Tour               — "Can I see the shape of Luce in one sitting?"
//!   Guide              — "How do I learn a language idea or build a program?"
//!   Reference          — "What is the exact rule or spelling?"
//!   Library            — "What does a shipped module or package provide?"
//!   Status             — "What is implemented today?"
//!
pub const Page = struct {
    /// The URL path under the section.
    slug: []const u8,
    title: []const u8,
    /// Optional source path when a page is being reorganized without
    /// duplicating its checked examples in the repository.
    source: ?[]const u8 = null,
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
        .title = "A Luce tour",
        .blurb = "One page that shows the language's shape: values, control flow, data, ownership, failure and workers.",
        .pages = &.{},
    },
    .{
        .slug = "guide",
        .label = "Guide",
        .title = "The Luce guide",
        .blurb = "Learn the language from a first executable through data, ownership, failure, packages and concurrency.",
        .pages = &.{
            .{ .slug = "toolchain", .title = "Build and run Luce programs", .source = "guide/toolchain.md", .blurb = "Install the compiler and editor, build an executable, and choose another artifact only when you need one." },
            .{ .slug = "editor", .title = "Editor and VS Code", .source = "guide/editor.md", .blurb = "Use the shipped editor or the local VS Code extension with the same compiler." },
            .{ .slug = "first-program", .title = "Hello and arguments", .source = "guide/first-program.md", .blurb = "The smallest complete program, and reading the command line." },
            .{ .slug = "values", .title = "Values and types", .source = "guide/values.md", .blurb = "Numbers, strings, enums and function values, plus the one-way numeric promotion rules." },
            .{ .slug = "control", .title = "Control flow", .source = "guide/control.md", .blurb = "Conditions, loops, matching and the explicit forms the parser refuses to guess at." },
            .{ .slug = "functions", .title = "Functions and structs", .source = "guide/functions.md", .blurb = "Parameters, returns, function values, lambdas and the first value types that hold behavior." },
            .{ .slug = "enums", .title = "Enums", .source = "guide/enums.md", .blurb = "A name for every number that is secretly a set, and the match that checks you covered them." },
            .{ .slug = "collections", .title = "Collections", .source = "guide/collections.md", .blurb = "Choose a list, map or fixed-shape array by the question your data needs to answer." },
            .{ .slug = "lists", .title = "Lists", .source = "guide/lists.md", .blurb = "Building, comparator sorting, searching, and slicing in a complete program." },
            .{ .slug = "maps", .title = "Maps", .source = "guide/maps.md", .blurb = "Insertion-ordered dictionaries with O(1) lookup in a complete program." },
            .{ .slug = "arrays", .title = "Arrays and grids", .source = "guide/arrays.md", .blurb = "Fixed-shape numeric storage, up to four dimensions." },
            .{ .slug = "text", .title = "Text processing", .source = "guide/text.md", .blurb = "Splitting, joining, trimming, and counting with std.strings." },
            .{ .slug = "files", .title = "Files", .source = "guide/files.md", .blurb = "Reading and writing through std.files, with the failure handled." },
            .{ .slug = "constants", .title = "Constants and shared tables", .source = "guide/constants.md", .blurb = "File-scope const, map literals, program-root identity, and the immutable boundary." },
            .{ .slug = "modules", .title = "Modules", .source = "guide/modules.md", .blurb = "A file is a module; the standard library lives under std." },
            .{ .slug = "visibility", .title = "Visibility", .source = "guide/visibility.md", .blurb = "Public until it says private: the marker, struct regions, and factory pattern." },
            .{ .slug = "organization", .title = "Organize a project and make a package", .source = "guide/organization.md", .blurb = "Keep local source packages beside main.luc, add a manifest when you are ready, and version the package." },
            .{ .slug = "structures", .title = "Structures: keep data and invariants together", .source = "guide/structures.md", .blurb = "Choose fields and methods, preserve invariants, and decide when a struct should own an object." },
            .{ .slug = "interfaces", .title = "Interfaces", .source = "guide/interfaces.md", .blurb = "Share a small behavior across different structs, with explicit contracts and visible ownership." },
            .{ .slug = "strings", .title = "Strings and copies", .source = "guide/strings.md", .blurb = "Immutable UTF-8 values with an owner, small-string optimisation, and the one benchmark still behind." },
            .{ .slug = "memory", .title = "Memory without a collector", .source = "guide/memory.md", .blurb = "Why scope ownership, what it costs, and how it compares to the alternatives that were refused." },
            .{ .slug = "ownership-example", .title = "give, copy and free", .source = "guide/ownership-example.md", .blurb = "The four situations where memory needs a word from you." },
            .{ .slug = "optionals", .title = "Optionals", .source = "guide/optionals.md", .blurb = "parse_int, none, narrowing, and the else fallback." },
            .{ .slug = "errors", .title = "Errors", .source = "guide/errors.md", .blurb = "A fallible function, try, catch, and an uncaught error's one-line report." },
            .{ .slug = "failure", .title = "Traps are bugs, errors are news", .source = "guide/failure.md", .blurb = "The one rule that decides whether a failure is a trap, an error, or an absence." },
            .{ .slug = "traps", .title = "Traps", .source = "guide/traps.md", .blurb = "What a bug looks like: a stable code, a line, and a call trace." },
            .{ .slug = "unions", .title = "Unions: make alternatives explicit", .source = "guide/unions.md", .blurb = "Model several valid shapes, match them safely, and keep payload ownership explicit." },
            .{ .slug = "concurrency", .title = "Concurrency and workers", .source = "guide/concurrency.md", .blurb = "Build multi-threaded work with share-nothing runtimes, explicit ownership and structured joins." },
            .{ .slug = "host", .title = "The outside world", .source = "guide/host.md", .blurb = "Arguments, files, terminals, and host services: every effect is explicit and fallible." },
            .{ .slug = "testing", .title = "Testing", .source = "guide/testing.md", .blurb = "Write ordinary test functions and keep failures visible and repeatable." },
            .{ .slug = "programs", .title = "The bundled programs", .source = "guide/programs.md", .blurb = "Real userland programs, included from source and exercised by the site." },
            .{ .slug = "performance", .title = "Performance", .source = "guide/performance.md", .blurb = "The benchmark table against C twins, what it measures, and what it does not." },
        },
    },
    .{
        .slug = "reference",
        .label = "Reference",
        .title = "The Luce reference",
        .blurb = "The exhaustive language reference: exact syntax, types, semantics, diagnostics and builtins.",
        .pages = &.{
            .{ .slug = "lexical", .title = "Source text and lexical elements", .source = "reference/lexical.md", .blurb = "Encoding, indentation, comments, literals, keywords and operators." },
            .{ .slug = "types", .title = "Types", .source = "reference/types.md", .blurb = "Values, function signatures, heap objects, optionals, interfaces and resources." },
            .{ .slug = "expressions", .title = "Expressions", .source = "reference/expressions.md", .blurb = "Operators, precedence, calls, lambdas, indexing, slicing and refused shapes." },
            .{ .slug = "statements", .title = "Statements and declarations", .source = "reference/statements.md", .blurb = "let, var, assignment, control flow, func, struct and file-scope constants." },
            .{ .slug = "ownership", .title = "Ownership", .source = "reference/ownership.md", .blurb = "The ratified memory model, S1 to S46, each one addressable on its own." },
            .{ .slug = "failure", .title = "Traps and errors", .source = "reference/failure.md", .blurb = "Every trap code, both error codes, and what each one means." },
            .{ .slug = "modules", .title = "Modules", .source = "reference/modules.md", .blurb = "Imports, visibility, packages and the std namespace." },
            .{ .slug = "builtins", .title = "Builtins", .source = "reference/builtins.md", .blurb = "Every free function and every method, with its signature." },
        },
    },
    .{
        .slug = "library",
        .label = "Library",
        .title = "Library",
        .blurb = "The standard modules and maintained packages that ship with Luce, with signatures, examples and limits.",
        .pages = &.{
            .{ .slug = "math", .title = "std.math", .blurb = "Transcendentals, integer powers, whole-array reductions, and a seeded generator." },
            .{ .slug = "strings", .title = "std.strings", .blurb = "Everything built on the String primitives: find, split, join, trim, case, padding." },
            .{ .slug = "files", .title = "std.files", .blurb = "A thin, fallible layer over the host's file services." },
            .{ .slug = "lists", .title = "std.lists", .blurb = "Stable comparator sorting for every list element type, with named functions or capture-free lambdas." },
            .{ .slug = "paths", .title = "std.paths", .blurb = "Pure text over path names: join, base, dir, extension, stem." },
            .{ .slug = "os", .title = "std.os", .blurb = "The machine's own facts: how much memory it has, how much is left, how many processors." },
            .{ .slug = "term", .title = "std.term", .blurb = "Terminal drawing and keyboard, mouse, and resize events." },
            .{ .slug = "termui", .title = "termui", .source = "library/termui.md", .blurb = "A deterministic terminal-UI surface built from a renderer, cells, views, layout and events." },
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
