//! The site's table of contents, as a table.
//!
//! One row per page, in reading order. The order is editorial: it follows
//! the path a reader takes through the language, not the order files happened
//! to be created in.
//!
//! Four sections form the public documentation:
//!
//!   Tour      — "Can I see the shape of Luce in one sitting?"
//!   Guide     — "How do I learn Luce, then look up an exact rule?"
//!   Library   — "What does a shipped module or package provide?"
//!   Status    — "What is implemented today?"
//!
//! The Guide is one book with three parts. Its teaching chapters come first,
//! tools and project work follow, and the intentionally dry language reference
//! closes the book. That distinction belongs inside the book, not in the top
//! navigation.

pub const Page = struct {
    /// The URL path under the section.
    slug: []const u8,
    title: []const u8,
    /// A visible chapter group. Equal names must be contiguous.
    part: []const u8,
    /// Optional source path when URL and source organization differ.
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
        .blurb = "Learn the language in a deliberate sequence, build real programs, then look up the exact rules in the same book.",
        .pages = &.{
            // Language Guide — teaching chapters, from common ground to the
            // boundaries that matter in larger programs.
            .{ .slug = "basics", .title = "The Basics", .part = "Language Guide", .source = "guide/basics.md", .blurb = "A complete program, values, types, bindings and command-line arguments." },
            .{ .slug = "operators", .title = "Basic Operators", .part = "Language Guide", .source = "guide/operators.md", .blurb = "Arithmetic, comparison, Boolean logic, assignment and the checks behind them." },
            .{ .slug = "strings", .title = "Strings and Text", .part = "Language Guide", .blurb = "Immutable UTF-8 values, searching, reshaping, building and ownership." },
            .{ .slug = "collections", .title = "Collection Types", .part = "Language Guide", .blurb = "Choose and use lists, maps and fixed-shape arrays." },
            .{ .slug = "control", .title = "Control Flow", .part = "Language Guide", .blurb = "Conditions, loops, matching, early exits and recursion." },
            .{ .slug = "functions", .title = "Functions", .part = "Language Guide", .blurb = "Parameters, returns, multiple values, lambdas, stored functions and bound methods." },
            .{ .slug = "enums", .title = "Enumerations", .part = "Language Guide", .blurb = "Named alternatives, numeric representation, exhaustive matching and methods." },
            .{ .slug = "structures", .title = "Structures and Methods", .part = "Language Guide", .blurb = "Keep data, behavior and invariants together in a value type." },
            .{ .slug = "constants", .title = "Constants", .part = "Language Guide", .blurb = "File-scope values, compile-time folding, shared tables and immutability." },
            .{ .slug = "optionals", .title = "Optionals", .part = "Language Guide", .blurb = "Represent absence, narrow it safely and provide a fallback." },
            .{ .slug = "unions", .title = "Unions", .part = "Language Guide", .blurb = "Model several valid shapes and match their payloads safely." },
            .{ .slug = "interfaces", .title = "Interfaces", .part = "Language Guide", .blurb = "Share behavior across different structures with checked, explicit contracts." },
            .{ .slug = "errors", .title = "Error Handling", .part = "Language Guide", .blurb = "Distinguish absence, recoverable errors and traps; propagate or handle each deliberately." },
            .{ .slug = "concurrency", .title = "Concurrency", .part = "Language Guide", .blurb = "Build multi-threaded work with isolated runtimes, explicit ownership and structured joins." },
            .{ .slug = "memory", .title = "Memory and Ownership", .part = "Language Guide", .blurb = "Understand scope ownership, borrowing, resources and the model's guarantees." },
            .{ .slug = "ownership-operations", .title = "Ownership Operations", .part = "Language Guide", .source = "guide/ownership-operations.md", .blurb = "Use give, copy and free in the few places where the default is not enough." },
            .{ .slug = "access-control", .title = "Access Control", .part = "Language Guide", .source = "guide/access-control.md", .blurb = "Choose public and private boundaries for modules and structures." },
            .{ .slug = "modules", .title = "Modules and Imports", .part = "Language Guide", .blurb = "Split a program into source files, imports, standard modules and aliases." },
            .{ .slug = "host", .title = "Host Services", .part = "Language Guide", .blurb = "Use arguments, files, terminals, clocks and other explicit effects." },

            // Tools and Projects — things a reader does around language code.
            .{ .slug = "command-line", .title = "Command-Line Tools", .part = "Tools and Projects", .source = "guide/command-line.md", .blurb = "Install Luce, build and run programs, and choose an artifact or build mode." },
            .{ .slug = "editor", .title = "Editor Support", .part = "Tools and Projects", .blurb = "Use the shipped editor or the local VS Code extension with the same compiler." },
            .{ .slug = "packages", .title = "Packages and Projects", .part = "Tools and Projects", .source = "guide/packages.md", .blurb = "Keep source packages beside main.luc, add a manifest, version them and prepare publication." },
            .{ .slug = "testing", .title = "Testing", .part = "Tools and Projects", .blurb = "Write ordinary test functions and keep failures visible and repeatable." },
            .{ .slug = "programs", .title = "Complete Programs", .part = "Tools and Projects", .blurb = "Read complete programs that combine modules, data, failure and the standard library." },
            .{ .slug = "performance", .title = "Performance", .part = "Tools and Projects", .blurb = "Measure release builds and choose efficient text and numeric storage without guessing." },

            // Language Reference — exhaustive lookup chapters in the same book.
            .{ .slug = "reference", .title = "About the Language Reference", .part = "Language Reference", .source = "guide/reference/index.md", .blurb = "How to read the exact syntax and semantic rules that close this book." },
            .{ .slug = "reference/lexical", .title = "Lexical Structure", .part = "Language Reference", .source = "guide/reference/lexical.md", .blurb = "Encoding, indentation, comments, literals, keywords and operators." },
            .{ .slug = "reference/types", .title = "Types", .part = "Language Reference", .source = "guide/reference/types.md", .blurb = "Values, function signatures, heap objects, optionals, interfaces and resources." },
            .{ .slug = "reference/expressions", .title = "Expressions", .part = "Language Reference", .source = "guide/reference/expressions.md", .blurb = "Operators, precedence, calls, lambdas, indexing, slicing and refused shapes." },
            .{ .slug = "reference/statements", .title = "Statements and Declarations", .part = "Language Reference", .source = "guide/reference/statements.md", .blurb = "Bindings, assignment, control flow, functions, structures and file-scope constants." },
            .{ .slug = "reference/ownership", .title = "Ownership", .part = "Language Reference", .source = "guide/reference/ownership.md", .blurb = "The complete ownership model, with every rule addressable on its own." },
            .{ .slug = "reference/failure", .title = "Errors and Traps", .part = "Language Reference", .source = "guide/reference/failure.md", .blurb = "Every stable error and trap code, and the conditions that produce it." },
            .{ .slug = "reference/modules", .title = "Modules", .part = "Language Reference", .source = "guide/reference/modules.md", .blurb = "Imports, visibility, packages and the std namespace." },
            .{ .slug = "reference/builtins", .title = "Built-in Functions and Methods", .part = "Language Reference", .source = "guide/reference/builtins.md", .blurb = "Every built-in free function and method, with its signature." },
        },
    },
    .{
        .slug = "library",
        .label = "Library",
        .title = "Library",
        .blurb = "The standard modules and maintained packages that ship with Luce, with signatures, examples and limits.",
        .pages = &.{
            .{ .slug = "math", .title = "std.math", .part = "Standard Library", .blurb = "Transcendentals, integer powers, whole-array reductions, and a seeded generator." },
            .{ .slug = "strings", .title = "std.strings", .part = "Standard Library", .blurb = "Everything built on the String primitives: find, split, join, trim, case, padding." },
            .{ .slug = "files", .title = "std.files", .part = "Standard Library", .blurb = "A thin, fallible layer over the host's file services." },
            .{ .slug = "lists", .title = "std.lists", .part = "Standard Library", .blurb = "Stable comparator sorting for every list element type, with named functions or capture-free lambdas." },
            .{ .slug = "paths", .title = "std.paths", .part = "Standard Library", .blurb = "Pure text over path names: join, base, dir, extension, stem." },
            .{ .slug = "os", .title = "std.os", .part = "Standard Library", .blurb = "The machine's own facts: how much memory it has, how much is left, how many processors." },
            .{ .slug = "term", .title = "std.term", .part = "Standard Library", .blurb = "Terminal drawing and keyboard, mouse, and resize events." },
            .{ .slug = "zip", .title = "std.zip", .part = "Standard Library", .blurb = "ZIP archives and DEFLATE, in pure Luce: read a real archive, write one, and check it." },
            .{ .slug = "json", .title = "std.json", .part = "Standard Library", .blurb = "JSON against RFC 8259, as a union: match a value, build one, write it back." },
            .{ .slug = "gpu", .title = "std.gpu", .part = "Standard Library", .blurb = "Backend-neutral surfaces for low-level drawing, with Metal and Vulkan kept behind the host boundary." },
            .{ .slug = "ui", .title = "std.ui", .part = "Standard Library", .blurb = "Windows and their drawing surfaces, before a higher-level UI package exists." },
            .{ .slug = "termui", .title = "termui", .part = "Maintained Packages", .source = "library/termui.md", .blurb = "A deterministic terminal-UI surface built from a renderer, cells, views, layout and events." },
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

test "sections, slugs, and chapter groups are coherent" {
    const std = @import("std");
    for (sections, 0..) |section, section_index| {
        try std.testing.expect(section.slug.len > 0);
        try std.testing.expect(section.pages.len < 40);
        for (sections[section_index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, section.slug, other.slug));
            try std.testing.expect(!std.mem.eql(u8, section.label, other.label));
        }

        var previous_part: []const u8 = "";
        for (section.pages, 0..) |page, position| {
            try std.testing.expect(page.slug.len > 0);
            try std.testing.expect(page.part.len > 0);
            try std.testing.expect(page.blurb.len > 0);
            for (section.pages[position + 1 ..]) |sibling| {
                try std.testing.expect(!std.mem.eql(u8, page.slug, sibling.slug));
            }

            if (!std.mem.eql(u8, page.part, previous_part)) {
                // Once a part ends, it cannot reappear later. This keeps the
                // sidebar and section index visibly grouped.
                for (section.pages[0..position]) |earlier| {
                    if (std.mem.eql(u8, earlier.part, page.part)) {
                        try std.testing.expect(std.mem.eql(u8, earlier.part, previous_part));
                    }
                }
                previous_part = page.part;
            }
        }
    }
}
