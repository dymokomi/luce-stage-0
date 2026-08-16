//! Ownership of the executable specification's tests.
//!
//! `src/luce/specs.zig` remains one test binary for the release gate: compiling
//! and loading the LLVM-backed harness once is materially cheaper and safer
//! than doing it once per suite.  These prefixes give every test in that
//! binary exactly one logical owner, power the focused `zig build test-*`
//! lanes, and let the progress runner report the fused run by suite.

const std = @import("std");

pub const Suite = enum {
    language,
    standard_library,
    host,
    backend,
    editor,
    examples,
    harness,
};

pub const Definition = struct {
    suite: Suite,
    label: []const u8,
    step: []const u8,
    description: []const u8,
    filters: []const []const u8,
};

pub const definitions = [_]Definition{
    .{
        .suite = .language,
        .label = "language",
        .step = "test-language",
        .description = "Run the core language's differential specification",
        .filters = &.{
            "specs.behavior_spec.",
            "specs.text_types_spec.",
            "specs.enums_spec.",
            "specs.union_spec.",
            "specs.errors_spec.",
            "specs.functions_spec.",
            "specs.closures_spec.",
            "specs.interfaces_spec.",
            "specs.aliases_spec.",
            "specs.weak_references_spec.",
            "specs.classes_spec.",
            "specs.self_spec.",
            "specs.binding_spec.",
            "specs.constants_spec.",
            "specs.threads_spec.",
            "specs.modules_spec.",
            "specs.optimize_spec.",
            "specs.format_spec.",
            "specs.testing_spec.",
        },
    },
    .{
        .suite = .standard_library,
        .label = "stdlib",
        .step = "test-stdlib",
        .description = "Run the standard-library specification",
        .filters = &.{
            "specs.std_spec.",
            "specs.json_spec.",
            "specs.zip_spec.",
        },
    },
    .{
        .suite = .host,
        .label = "host",
        .step = "test-host",
        .description = "Run the language host-boundary specification",
        .filters = &.{
            "specs.host_spec.",
            "specs.bytes_spec.",
        },
    },
    .{
        .suite = .backend,
        .label = "backend",
        .step = "test-backend",
        .description = "Run the LLVM backend's end-to-end specification",
        .filters = &.{"codegen.test."},
    },
    .{
        .suite = .editor,
        .label = "editor",
        .step = "test-editor",
        .description = "Run the editor's differential and userland tests",
        .filters = &.{"specs.editor_spec."},
    },
    .{
        .suite = .examples,
        .label = "examples",
        .step = "test-examples",
        .description = "Run the example-program specification and build checks",
        .filters = &.{"specs.adventure_spec."},
    },
    .{
        .suite = .harness,
        .label = "spec-harness",
        .step = "test-spec-harness",
        .description = "Run the differential harness's own tests",
        .filters = &.{
            "specs.agree.",
            "specs.hosts.",
        },
    },
};

pub fn definition(suite: Suite) *const Definition {
    for (&definitions) |*candidate| {
        if (candidate.suite == suite) return candidate;
    }
    unreachable;
}

/// The number of suite prefixes matching a fully qualified Zig test name.
/// It is public because both the runner and the structural audit fail closed
/// unless the answer is exactly one.
pub fn matchCount(name: []const u8) usize {
    var count: usize = 0;
    for (definitions) |candidate| {
        for (candidate.filters) |prefix| {
            count += @intFromBool(std.mem.startsWith(u8, name, prefix));
        }
    }
    return count;
}

pub fn classify(name: []const u8) ?Suite {
    var answer: ?Suite = null;
    for (definitions) |candidate| {
        for (candidate.filters) |prefix| {
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            if (answer != null) return null;
            answer = candidate.suite;
        }
    }
    return answer;
}
