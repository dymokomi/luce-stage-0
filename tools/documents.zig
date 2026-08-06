//! Which documents the guards hold to the language, and in which of
//! the two senses.
//!
//! A list rather than a directory, because `docs/` holds both kinds
//! and only one of them is bound by the strict reading.
//!
//! It lives in a file of its own because two tools read it and neither
//! can import the other: `doccheck.zig` imports `luce` to compile the
//! samples, and `spelling.zig` imports nothing at all and should keep
//! it that way.  They kept a list each, "meant to be read together",
//! and they disagreed by one — `docs/README.md` was spell-guarded and
//! its samples were never compiled.  One declaration, one truth.
//!
//! Paths are relative to the repository root, which is where the build
//! runs its tests from — the same assumption `tools/grammar.zig`
//! makes.

/// **Living** documents: a reader may paste any of this into a file
/// and have it work today.  Their Luce must compile, their prose may
/// not spell a retired type name, and they carry no exemptions.
pub const living = [_][]const u8{
    "docs/LANGUAGE.md",
    "docs/OWNERSHIP.md",
    "docs/STD.md",
    "docs/CODEGEN.md",
    "docs/MISSING.md",
    "docs/ENGINE.md",
    "docs/MODES.md",
    "docs/PIPELINE.md",
    "docs/README.md",
    "README.md",
    "CLAUDE.md",
};

/// **Decision records**: what was decided and when.  Their code is
/// checked too — a memo that shows the language of its day is welcome
/// to, and says so with `historical`; what it may not do is show code
/// that reads as current and is not.  The tag is the whole exemption
/// and one grep lists every use of it.
pub const records = [_][]const u8{
    "docs/METHODS.md",
    "docs/RETURNS.md",
    "docs/NUMERICS.md",
    "docs/STRINGS.md",
    "docs/FAILURE.md",
    "docs/MEMORY.md",
    "docs/V2.md",
    "docs/TYPES.md",
    "docs/VECTOR.md",
    "docs/ARGS.md",
    "docs/VISIBILITY.md",
};

/// Both, living first — so "the living documents carry no exemptions"
/// is a slice rather than a convention.
pub const all = living ++ records;
