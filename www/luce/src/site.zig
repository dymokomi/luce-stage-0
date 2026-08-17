//! The site's table of contents, as a table.
//!
//! One row per page, in reading order. The order is editorial: it follows
//! the path a reader takes through the language, not the order files happened
//! to be created in.
//!
//! Five sections form the public documentation:
//!
//!   Tour      — "Can I see the shape of Luce in one sitting?"
//!   Guide     — "How do I learn Luce, then look up an exact rule?"
//!   Tools     — "How do I install, build, edit, test, and package it?"
//!   Library   — "What does a shipped module or package provide?"
//!   Status    — "What is implemented today?"
//!
//! The Guide is one language book with two parts. Teaching chapters come
//! first; the intentionally dry reference closes the book. Toolchain and
//! project work have their own section so a language reader never has to step
//! through editor or package chapters to continue learning semantics.

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
        .blurb = "One page that shows the language's shape: values, control flow, data, ARC, failure and workers.",
        .pages = &.{},
    },
    .{
        .slug = "guide",
        .label = "Guide",
        .title = "The Luce guide",
        .blurb = "Learn the language in a deliberate sequence, then look up its exact grammar and semantics in the same book.",
        .pages = &.{
            // Language Guide — teaching chapters, from common ground to the
            // boundaries that matter in larger programs.
            .{ .slug = "about", .title = "About Luce", .part = "Language Guide", .blurb = "The language's goals, its safety model, and the boundaries it keeps explicit." },
            .{ .slug = "compatibility", .title = "Version Compatibility", .part = "Language Guide", .blurb = "What a 0.x release promises about source, native artifacts, packages, and the host ABI." },
            .{ .slug = "basics", .title = "The Basics", .part = "Language Guide", .source = "guide/basics.md", .blurb = "A complete program, values, types, bindings and command-line arguments." },
            .{ .slug = "operators", .title = "Basic Operators", .part = "Language Guide", .source = "guide/operators.md", .blurb = "Arithmetic, comparison, Boolean logic, assignment and the checks behind them." },
            .{ .slug = "strings", .title = "Strings and Text", .part = "Language Guide", .blurb = "Immutable UTF-8 values, searching, reshaping, building and byte boundaries." },
            .{ .slug = "collections", .title = "Collection Types", .part = "Language Guide", .blurb = "Choose and use lists, maps and fixed-shape arrays." },
            .{ .slug = "control", .title = "Control Flow", .part = "Language Guide", .blurb = "Conditions, loops, matching, early exits and recursion." },
            .{ .slug = "functions", .title = "Functions", .part = "Language Guide", .blurb = "Declare and call functions with named/default arguments, multiple results, failure, and function values." },
            .{ .slug = "closures", .title = "Closures", .part = "Language Guide", .blurb = "Carry local state in block closures, choose strong, weak, or snapshot captures, and store callbacks safely." },
            .{ .slug = "enums", .title = "Enumerations", .part = "Language Guide", .blurb = "Named alternatives, numeric representation, exhaustive matching and methods." },
            .{ .slug = "structures", .title = "Structures", .part = "Language Guide", .blurb = "Model related data as a value that copies predictably." },
            .{ .slug = "classes", .title = "Classes", .part = "Language Guide", .blurb = "Choose shared mutable identity and understand how class aliases differ from copied structures." },
            .{ .slug = "methods", .title = "Methods", .part = "Language Guide", .blurb = "Attach instance and static behavior, understand `self`, mutation, binding, and call syntax." },
            .{ .slug = "initialization", .title = "Initialization", .part = "Language Guide", .blurb = "Construct structures and classes, use defaults, and establish every class field before identity exists." },
            .{ .slug = "deinitialization", .title = "Deinitialization", .part = "Language Guide", .blurb = "Perform deterministic class cleanup at the last strong release without resurrection or manual memory calls." },
            .{ .slug = "optionals", .title = "Optionals", .part = "Language Guide", .blurb = "Represent absence, narrow it safely and provide a fallback." },
            .{ .slug = "unions", .title = "Unions", .part = "Language Guide", .blurb = "Model several valid shapes and match their payloads safely." },
            .{ .slug = "errors", .title = "Error Handling", .part = "Language Guide", .blurb = "Distinguish absence, recoverable errors and traps; propagate or handle each deliberately." },
            .{ .slug = "concurrency", .title = "Concurrency", .part = "Language Guide", .blurb = "Build multi-threaded work with isolated runtimes, copied values, and structured joins." },
            .{ .slug = "interfaces", .title = "Interfaces", .part = "Language Guide", .blurb = "Share behavior across different structs and classes with checked, explicit contracts." },
            .{ .slug = "memory", .title = "Memory and ARC", .part = "Language Guide", .blurb = "Understand values, shared references, the resource-lifetime contract, and worker isolation." },
            .{ .slug = "access-control", .title = "Access Control", .part = "Language Guide", .source = "guide/access-control.md", .blurb = "Choose public and private boundaries for modules and structures." },
            .{ .slug = "constants", .title = "Global Constants", .part = "Language Guide", .blurb = "Share folded file-scope values and immutable program-root containers." },
            .{ .slug = "modules", .title = "Modules and Imports", .part = "Language Guide", .blurb = "Split a program into source files, imports, standard modules and aliases." },
            .{ .slug = "host", .title = "Host Effects", .part = "Language Guide", .blurb = "Use arguments, files, terminals, clocks, processes, windows, and other explicit effects." },

            // Language Reference — exhaustive lookup chapters in the same book.
            .{ .slug = "reference", .title = "About the Language Reference", .part = "Language Reference", .source = "guide/reference/index.md", .blurb = "How to read the exact syntax and semantic rules that close this book." },
            .{ .slug = "reference/lexical", .title = "Lexical Structure", .part = "Language Reference", .source = "guide/reference/lexical.md", .blurb = "Encoding, indentation, comments, literals, keywords and operators." },
            .{ .slug = "reference/types", .title = "Types", .part = "Language Reference", .source = "guide/reference/types.md", .blurb = "Values, function signatures, heap objects, optionals, interfaces and resources." },
            .{ .slug = "reference/expressions", .title = "Expressions", .part = "Language Reference", .source = "guide/reference/expressions.md", .blurb = "Operators, precedence, calls, lambdas, indexing, slicing and refused shapes." },
            .{ .slug = "reference/statements", .title = "Statements and Declarations", .part = "Language Reference", .source = "guide/reference/statements.md", .blurb = "Bindings, assignment, control flow, functions, structures and file-scope constants." },
            .{ .slug = "reference/memory", .title = "Memory Management", .part = "Language Reference", .source = "guide/reference/memory.md", .blurb = "The exact value-copy, ARC, resource, interface, and worker-boundary rules." },
            .{ .slug = "reference/failure", .title = "Errors and Traps", .part = "Language Reference", .source = "guide/reference/failure.md", .blurb = "Every stable error and trap code, and the conditions that produce it." },
            .{ .slug = "reference/modules", .title = "Modules", .part = "Language Reference", .source = "guide/reference/modules.md", .blurb = "Imports, visibility, packages and the std namespace." },
            .{ .slug = "reference/builtins", .title = "Built-in Functions and Methods", .part = "Language Reference", .source = "guide/reference/builtins.md", .blurb = "Every standalone built-in and receiver method, with its signature." },
        },
    },
    .{
        .slug = "tools",
        .label = "Tools",
        .title = "Command-Line Tools",
        .blurb = "Install Luce, build and edit programs, organize packages, run tests, and measure real applications.",
        .pages = &.{
            .{ .slug = "command-line", .title = "The luce and loom Commands", .part = "Toolchain", .source = "tools/command-line.md", .blurb = "Install the toolchain, build and run programs, and choose an artifact or build mode." },
            .{ .slug = "editor", .title = "Editor Support", .part = "Toolchain", .source = "tools/editor.md", .blurb = "Use the shipped declarative terminal editor or the local VS Code extension." },
            .{ .slug = "packages", .title = "Packages and Projects", .part = "Projects", .source = "tools/packages.md", .blurb = "Keep source packages beside main.luc, add a manifest, version them, and understand the absent registry boundary." },
            .{ .slug = "testing", .title = "Testing", .part = "Projects", .source = "tools/testing.md", .blurb = "Write ordinary test functions and keep discovery, progress, and failures visible and repeatable." },
            .{ .slug = "programs", .title = "Complete Programs", .part = "Projects", .source = "tools/programs.md", .blurb = "Read complete programs that combine modules, data, failure, concurrency, and the standard library." },
            .{ .slug = "performance", .title = "Performance", .part = "Projects", .source = "tools/performance.md", .blurb = "Measure release builds and choose efficient text and numeric storage without guessing." },
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
            .{ .slug = "lists", .title = "std.lists", .part = "Standard Library", .blurb = "Stable comparator sorting for every list element type, with named functions or closures." },
            .{ .slug = "paths", .title = "std.paths", .part = "Standard Library", .blurb = "Pure text over path names: join, base, dir, extension, stem." },
            .{ .slug = "os", .title = "std.os", .part = "Standard Library", .blurb = "The machine's own facts: how much memory it has, how much is left, how many processors." },
            .{ .slug = "term", .title = "std.term", .part = "Standard Library", .blurb = "Terminal drawing and keyboard, mouse, and resize events." },
            .{ .slug = "zip", .title = "std.zip", .part = "Standard Library", .blurb = "ZIP archives and DEFLATE, in pure Luce: read a real archive, write one, and check it." },
            .{ .slug = "json", .title = "std.json", .part = "Standard Library", .blurb = "JSON against RFC 8259, as a union: match a value, build one, write it back." },
            .{ .slug = "gpu", .title = "std.gpu", .part = "Standard Library", .blurb = "Backend-neutral surfaces for low-level drawing, with Metal and Vulkan kept behind the host boundary." },
            .{ .slug = "ui", .title = "std.ui", .part = "Standard Library", .blurb = "Windows and their drawing surfaces, before a higher-level UI package exists." },
            .{ .slug = "network", .title = "std.network", .part = "Standard Library", .blurb = "TCP connections and listeners: dial a host, open a door, move bytes." },
            .{ .slug = "http", .title = "std.http", .part = "Standard Library", .blurb = "The HTTP/1.1 client, in pure Luce: fetch a page, read the answer, and a status code is data." },
            .{ .slug = "termui", .title = "termui", .part = "Maintained Packages", .source = "library/termui.md", .blurb = "Declarative terminal applications built from stacks, panels, rows, events, and one hidden lifecycle." },
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
    const expected_sections = [_][]const u8{ "tour", "guide", "tools", "library", "status" };
    try std.testing.expectEqual(expected_sections.len, sections.len);
    for (sections, expected_sections) |section, expected| {
        try std.testing.expectEqualStrings(expected, section.slug);
    }

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

    for (sections[1].pages) |page| {
        try std.testing.expect(
            std.mem.eql(u8, page.part, "Language Guide") or
                std.mem.eql(u8, page.part, "Language Reference"),
        );
    }
    for (sections[2].pages) |page| {
        try std.testing.expect(
            std.mem.eql(u8, page.part, "Toolchain") or
                std.mem.eql(u8, page.part, "Projects"),
        );
    }
}
