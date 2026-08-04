//! An artifact's tag: what a compiled Luce module says about itself,
//! and what a loader checks before it believes any of it.
//!
//! **A native artifact is not portable, and the file name cannot be
//! trusted to say so.**  A `.lc` copied between machines, kept across
//! an ABI bump, built by a since-upgraded toolchain, or built from a
//! since-edited program is a file that still loads and still has a
//! `luce_main` to call — and calling it would be a crash with no
//! explanation.  So `08_llvm/lower.zig` stamps every artifact with the
//! constant below, and a loader refuses by name.
//!
//! **A separate contract from the host ABI, on purpose.**  `abi.zig`
//! is what generated code and a host agree on; this is what a *loader*
//! reads, and it has to read it before it can believe anything else —
//! including which host ABI the code was generated against, which is
//! one field in here.  So the two carry their own version numbers and
//! move on their own schedules: `abi.version` changes a few times a
//! year, `generator` below changes whenever the code generator does,
//! and `format` only when the shape of the saying itself changes.  The
//! one thing this file takes from the ABI is that single field's value.
//!
//! The consumers are disjoint as well: eight loader sites read this and
//! never touch `abi.Host`, and the lowering touches it in one place.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");

/// One number computed by `build.zig` and compiled into both binaries:
/// what produced an artifact's machine code (`generator` below).
const build_options = @import("build_options");

/// The symbol a compiled Luce artifact exports its tag as.  What to
/// *call* is `abi.entry_symbol`.
pub const symbol = "luce_artifact";

/// The machine an artifact runs on, as a string both the compiler and
/// the loader can produce.
///
/// **Not the LLVM triple, deliberately.**  The triple is a *codegen*
/// input — LLVM invents it, LLVM parses it, and asking for it means
/// linking libLLVM.  A loader is asking a different question: may this
/// shared library be opened and called here?  Architecture, operating
/// system and C ABI answer that question exactly, they come from
/// `builtin` at compile time, and they cost a `loom` that only ever
/// *runs* programs no dependency at all (`docs/CODEGEN.md`).
///
/// CPU features are absent because nothing generates for a named CPU:
/// `emit.Options.cpu` is empty, measured rather than assumed.  The day
/// that changes, this string grows and `version` moves with it.
pub const machine = @tagName(builtin.cpu.arch) ++
    "-" ++ @tagName(builtin.os.tag) ++
    "-" ++ @tagName(builtin.abi);

/// What produced the machine code, as one number.
///
/// `source_hash` below says which *program* an artifact holds; this
/// says which *compiler* wrote it.  They are different facts and a
/// loader owes a person the right one: "you edited the program" and
/// "you upgraded the toolchain" are not the same sentence, and only
/// one of them is something the user did to the program.
///
/// **Not a version anyone maintains.**  `build.zig` hashes what
/// actually decides the answer — the lowering and the emitter, the
/// runtime library the link puts inside the artifact, and the LLVM
/// that optimizes what they emit — because a code generator changes
/// far more often than an ABI, and a number somebody has to remember
/// to bump is a number that will not be bumped.  It is a content hash
/// and nothing else, so a rebuilt-but-unchanged toolchain produces the
/// same one and the cache keeps working.
///
/// It costs a loader nothing: both binaries come out of one
/// `zig build`, so `loom` compares its own compiled-in constant
/// against the artifact's and never looks at the compiler at all.
pub const generator: u64 = build_options.generator;

/// The layout version of `Artifact` itself.  Separate from `version`
/// because a loader has to read the tag *before* it can believe
/// anything else in it: the tag says what the artifact is, and if the
/// shape of the saying changes, an old loader must refuse rather than
/// misread the fields after it.
///
/// 2 — `generator` arrived at the end, so an artifact says which code
/// generator wrote it and not only which program it holds.
pub const format: u32 = 2;

/// `LUCEART\0`, little-endian — the first eight bytes of the tag, so a
/// symbol of the right name but the wrong provenance is caught too.
pub const magic: u64 = 0x0054524145_43554c;

/// What an artifact says about itself, as an exported constant.
///
/// **A native artifact is not portable, and the file name cannot be
/// trusted to say so.**  A `.lc` copied between machines, kept across
/// an ABI bump, or built from a since-edited program is a file that
/// still loads and still has a `luce_main` to call — and calling it
/// would be a crash with no explanation.  So every artifact carries
/// this, and a loader refuses by name: wrong machine, wrong ABI, stale
/// program.  The check costs one symbol lookup and six comparisons,
/// once, before the first Luce instruction runs.
///
/// The text fields are borrowed from the artifact's own constant data
/// and last as long as it stays loaded.
pub const Artifact = extern struct {
    magic: u64 = magic,
    /// `format` above at the time it was written.
    format: u32 = format,
    /// The `version` of the host ABI the code was generated against.
    /// A loader must refuse anything but its own.
    abi_version: u32 = abi.version,
    /// The machine the code was generated for — `machine` above, e.g.
    /// `aarch64-macos-none`.  Not NUL-terminated.
    machine: [*]const u8,
    machine_length: i64,
    /// A hash of the serialized module the artifact was compiled from
    /// (`mir.module.encode`'s bytes).  This is the cache key, and it
    /// keys on *content*: a rebuilt-but-identical program matches, and
    /// a program whose bytes changed does not, whatever the clock or
    /// the file system says about either.
    source_hash: u64,
    /// Nonzero when the artifact carries per-instruction origins, so a
    /// trap can report `file:line:column` (docs/MODES.md).  Zero for a
    /// `--release` artifact, which still names its functions.
    debug: i32,
    reserved: i32 = 0,
    /// `generator` above at the time it was written: what produced
    /// these instructions.  A loader refuses anything but its own, so
    /// upgrading the compiler rebuilds every artifact rather than
    /// leaving the old code generator's output running.
    ///
    /// Appended rather than folded into `reserved` or `source_hash`:
    /// every field before it kept its offset, and a stale artifact
    /// gets to say *which* thing changed.
    generator: u64 = generator,
};

/// The cache key for a compiled artifact: a hash of the serialized
/// module it was compiled from.
///
/// **Content, never a timestamp.**  A modification time answers "was
/// this file touched", which is not the question — a rebuild that
/// produced identical bytes should hit the cache, and a file restored
/// from a backup with an old mtime must not.  The seed is fixed and
/// written down here because the compiler and the loader have to agree
/// on it across processes and across builds.
pub fn sourceHash(module_bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0x4c554345, module_bytes);
}

/// Why a loader refused an artifact, in the order a loader checks.
pub const Mismatch = enum {
    /// No `luce_artifact` symbol, or one that does not begin with the
    /// magic: this file was not produced by any Luce compiler.
    not_an_artifact,
    /// A tag whose own layout this loader cannot read.
    format,
    /// Built against a different host ABI.
    abi_version,
    /// Built for a different machine.
    machine,
    /// Built by a different code generator: the same program, but the
    /// instructions came out of a toolchain this loader is not part
    /// of, so what runs would not be what this build compiles.
    generator,
    /// Built from a different program.
    source,
};

/// Read and check an artifact's tag.  `tag` is whatever was found at
/// `artifact_symbol`; null means the symbol was missing.  `expect_hash`
/// is null when the caller has no particular program in mind (an
/// artifact being inspected rather than run from a cache).
///
/// The machine and the generator are checked against this loader's
/// own, which is the only answer that can be right: whoever is calling
/// is the machine, and whoever is calling was built by the compiler
/// whose output it will accept.  Everything intrinsic to the artifact
/// is settled before the caller's question about *which program*,
/// because an artifact can be unrunnable here regardless of it.
pub fn check(tag: ?*const Artifact, expect_hash: ?u64) ?Mismatch {
    const found = tag orelse return .not_an_artifact;
    if (found.magic != magic) return .not_an_artifact;
    if (found.format != format) return .format;
    if (found.abi_version != abi.version) return .abi_version;
    const named = found.machine[0..@intCast(found.machine_length)];
    if (!std.mem.eql(u8, named, machine)) return .machine;
    if (found.generator != generator) return .generator;
    if (expect_hash) |wanted| {
        if (found.source_hash != wanted) return .source;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "the artifact tag's layout is the one the code generator emits" {
    // `lower.describeArtifact` writes `{ i64, i32, i32, ptr, i64, i64,
    // i32, i32, i64 }`; if this struct moves, that must move with it,
    // and a loader reading a tag through the wrong offsets is the exact
    // failure the tag exists to prevent.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Artifact, "magic"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Artifact, "format"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(Artifact, "abi_version"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Artifact, "machine"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Artifact, "machine_length"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Artifact, "source_hash"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(Artifact, "debug"));
    try std.testing.expectEqual(@as(usize, 44), @offsetOf(Artifact, "reserved"));
    // Appended at `format` 2, which is what that bump was:
    // every offset above is the one format 1 had.
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(Artifact, "generator"));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(Artifact));
}

test "an artifact tag is refused by name, in the order a loader checks" {
    const elsewhere = "sparc64-solaris-none";
    try std.testing.expect(!std.mem.eql(u8, machine, elsewhere));

    var good: Artifact = .{
        .machine = machine.ptr,
        .machine_length = machine.len,
        .source_hash = 7,
        .debug = 1,
    };
    try std.testing.expectEqual(@as(?Mismatch, null), check(&good, 7));
    try std.testing.expectEqual(@as(?Mismatch, null), check(&good, null));
    try std.testing.expectEqual(Mismatch.source, check(&good, 8).?);
    try std.testing.expectEqual(Mismatch.not_an_artifact, check(null, 7).?);

    var wrong = good;
    wrong.machine = elsewhere.ptr;
    wrong.machine_length = elsewhere.len;
    try std.testing.expectEqual(Mismatch.machine, check(&wrong, 7).?);
    wrong = good;
    wrong.generator = generator +% 1;
    try std.testing.expectEqual(Mismatch.generator, check(&wrong, 7).?);
    // A different generator is refused even when nobody asked about
    // the program, because it is a fact about the artifact and not
    // about the question: `loom run NAME.lc` names no program to match.
    try std.testing.expectEqual(Mismatch.generator, check(&wrong, null).?);
    // And it is the answer given first when the program changed too:
    // the toolchain moving under an artifact is the more fundamental
    // of the two, and the one a person will not otherwise guess.
    try std.testing.expectEqual(Mismatch.generator, check(&wrong, 8).?);
    wrong = good;
    wrong.abi_version = abi.version + 1;
    try std.testing.expectEqual(Mismatch.abi_version, check(&wrong, 7).?);
    wrong = good;
    wrong.format = format + 1;
    try std.testing.expectEqual(Mismatch.format, check(&wrong, 7).?);
    wrong = good;
    wrong.magic = 0;
    try std.testing.expectEqual(Mismatch.not_an_artifact, check(&wrong, 7).?);
}

test "the machine names the architecture, the system, and the C ABI" {
    // Three fields, two separators, nothing invented: the same string
    // the compiler stamps is the one a loader compares against, because
    // it is one constant and both of them read it.
    var parts = std.mem.splitScalar(u8, machine, '-');
    try std.testing.expectEqualStrings(@tagName(builtin.cpu.arch), parts.next().?);
    try std.testing.expectEqualStrings(@tagName(builtin.os.tag), parts.next().?);
    try std.testing.expectEqualStrings(@tagName(builtin.abi), parts.next().?);
    try std.testing.expect(parts.next() == null);
}

test "the generator is a real number the build computed" {
    // Zero is what a `build.zig` that forgot would hand over, and an
    // artifact tagged zero would match every other one that forgot.
    try std.testing.expect(generator != 0);
    // It is a compile-time constant, so a loader pays nothing to check
    // it: no file is read, no binary is hashed, no compiler is found.
    try std.testing.expect(@TypeOf(generator) == u64);
    comptime std.debug.assert(generator != 0);
}

test "the source hash keys on content and nothing else" {
    try std.testing.expectEqual(sourceHash("LUCE\x01ab"), sourceHash("LUCE\x01ab"));
    try std.testing.expect(sourceHash("LUCE\x01ab") != sourceHash("LUCE\x01ac"));
    // Fixed seed: two processes and two builds must agree, so this
    // number is part of the format rather than an implementation
    // detail free to drift.
    try std.testing.expectEqual(@as(u64, std.hash.Wyhash.hash(0x4c554345, "x")), sourceHash("x"));
}
