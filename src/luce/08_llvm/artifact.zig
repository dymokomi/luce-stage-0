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
//!
//! **Nothing in the tag is a pointer, and that is what makes it
//! readable cold.**  The tag is read out of the file's own bytes, from
//! a named section, before any platform loader has opened the file —
//! and in a file nobody has loaded there are no addresses, only
//! relocations nothing has applied.  So the machine's name is a run of
//! bytes *inside* the tag rather than a pointer to one, and every
//! field is a number or a byte.  A reader needs the section's contents
//! and nothing else; `src/apps/native.zig` is that reader.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");

/// One number computed by `build.zig` and compiled into both binaries:
/// what produced an artifact's machine code (`generator` below).
const build_options = @import("build_options");

/// The symbol a compiled Luce artifact exports its tag as.  What to
/// *call* is `abi.entry_symbol`.
///
/// The symbol is not how a loader finds the tag — a symbol is a thing
/// you look up in a library you have already opened, and the whole
/// point of the tag is to be read before that.  It stays exported
/// because it costs nothing and an embedder holding an already-open
/// handle has no file to go back to.
pub const symbol = "luce_artifact";

/// Where the tag sits in the file, per container, so a reader can find
/// it in bytes nobody has loaded.
///
/// One section, two spellings, because the two formats name sections
/// differently and neither name is negotiable: Mach-O sections live in
/// a segment and are written `SEGMENT,SECTION`, ELF sections have one
/// flat name.  Both are spelled here and nowhere else — the emitter
/// writes what this says and the loader looks for what this says.
pub const section = struct {
    /// Mach-O: a segment of our own, so nothing else lands beside the
    /// tag and a reader that finds the section has found the tag.
    pub const mach_segment = "__LUCE";
    pub const mach_name = "__artifact";
    /// What the emitter writes for a Mach-O global.
    pub const mach = mach_segment ++ "," ++ mach_name;
    /// ELF: one flat name, in the compiler's own namespace.
    pub const elf = ".luce_artifact";
};

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

/// How much room the machine's name gets *inside* the tag.
///
/// The name is bytes rather than a pointer because the tag is read out
/// of a file nobody has loaded, where a pointer is an unapplied
/// relocation and not an address (see the header).  Fifty-two is
/// nearly three times the longest name any target this compiler runs
/// on produces (`aarch64-macos-none` is eighteen), and it is the
/// number that leaves `Artifact` with no padding at all — ninety-six
/// bytes of fields and nothing implicit between them, which is one
/// less thing for a reader of raw bytes to have to agree about.
pub const machine_capacity = 52;

/// A machine's name, carried in the tag as bytes.
pub const MachineName = extern struct {
    length: u32,
    text: [machine_capacity]u8,

    /// The machine this build is for.
    pub const here: MachineName = .of(machine);

    /// `name` in a tag's fixed run of bytes.  Longer than the run is a
    /// compile error rather than a silent truncation: a machine whose
    /// name does not fit is one this tag cannot describe, and shipping
    /// artifacts that describe themselves wrongly is the failure the
    /// tag exists to prevent.
    pub fn of(comptime called: []const u8) MachineName {
        if (called.len > machine_capacity) {
            @compileError("machine name does not fit the artifact tag: " ++ called);
        }
        var made: MachineName = .{ .length = called.len, .text = @splat(0) };
        @memcpy(made.text[0..called.len], called);
        return made;
    }

    /// The name, as text.  Clamped to the run it lives in, so a reader
    /// handed a damaged tag answers bytes it actually has rather than
    /// walking off the end — `check` refuses such a tag as `damaged`
    /// before any sentence is built out of one.
    pub fn name(self: *const MachineName) []const u8 {
        return self.text[0..@min(self.length, machine_capacity)];
    }
};

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
///
/// 3 — the machine's name moved *into* the tag and the pointer that
/// held it went, so the whole tag can be read out of a file before any
/// loader has applied a relocation.  The fields were reordered while
/// the shape was moving anyway, largest first, which is why no offset
/// from 2 survives and why this is a bump and not an append.
pub const format: u32 = 3;

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
/// program.  The check costs one small read of the file and six
/// comparisons, once, before the file is loaded at all.
///
/// **Numbers and bytes, no pointers** (see the header): every field is
/// something a reader can believe in a file nobody has relocated, and
/// a copy of the tag is the whole tag rather than a thing with borrows
/// in it.
pub const Artifact = extern struct {
    magic: u64 = magic,
    /// A hash of the serialized module the artifact was compiled from
    /// (`mir.module.encode`'s bytes).  This is the cache key, and it
    /// keys on *content*: a rebuilt-but-identical program matches, and
    /// a program whose bytes changed does not, whatever the clock or
    /// the file system says about either.
    source_hash: u64,
    /// `generator` above at the time it was written: what produced
    /// these instructions.  A loader refuses anything but its own, so
    /// upgrading the compiler rebuilds every artifact rather than
    /// leaving the old code generator's output running.
    generator: u64 = generator,
    /// `format` above at the time it was written.  Read before
    /// anything after it, which is why it sits as close to the magic
    /// as alignment allows.
    format: u32 = format,
    /// The `version` of the host ABI the code was generated against.
    /// A loader must refuse anything but its own.
    abi_version: u32 = abi.version,
    /// Nonzero when the artifact carries per-instruction origins, so a
    /// trap can report `file:line:column` (docs/MODES.md).  Zero for a
    /// `--release` artifact, which still names its functions.
    debug: i32,
    reserved: i32 = 0,
    /// The machine the code was generated for — `machine` above, e.g.
    /// `aarch64-macos-none`.  Last, because it is the only field that
    /// is not one machine word.
    machine: MachineName = .here,
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

/// Why a loader refused an artifact, in the order a loader checks —
/// and, where the refusal is a *disagreement*, what the artifact said,
/// so the sentence can name both sides.
///
/// "It was built for a different machine" leaves a person to work out
/// which two machines are meant, and the loader already knows: it is
/// one of them and it is holding the other's name.
pub const Mismatch = union(enum) {
    /// No tag in the file, or one that does not begin with the magic:
    /// this file was not produced by any Luce compiler.
    not_an_artifact,
    /// The file is truncated, or its object headers describe something
    /// that is not inside it.  Not a judgement about the program: the
    /// bytes that would say are not all there.
    damaged,
    /// A tag whose own layout this loader cannot read, and the layout
    /// version it claimed.
    format: u32,
    /// Built against a different host ABI, and which one.
    abi_version: u32,
    /// Built for a different machine, and which one.
    machine: MachineName,
    /// Built by a different code generator: the same program, but the
    /// instructions came out of a toolchain this loader is not part
    /// of, so what runs would not be what this build compiles.  There
    /// is no other side to name — a generator identity is a hash, and
    /// printing two of them helps nobody.
    generator,
    /// Built from a different program.
    source,

    /// Which refusal this is, without asking what it carries — what a
    /// caller that only wants to know *whether* it is this one asks.
    pub fn is(self: Mismatch, which: std.meta.Tag(Mismatch)) bool {
        return std.meta.activeTag(self) == which;
    }
};

/// Check an artifact's tag.  `tag` is whatever was read out of the
/// artifact's section; null means there was none.  `expect_hash` is
/// null when the caller has no particular program in mind (an artifact
/// being inspected rather than run from a cache).
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
    if (found.format != format) return .{ .format = found.format };
    // The shape says a name longer than the room it lives in, which no
    // tag this compiler writes can say.  Structure, not disagreement:
    // whatever produced these bytes, they are not a tag to reason from.
    if (found.machine.length > machine_capacity) return .damaged;
    if (found.abi_version != abi.version) return .{ .abi_version = found.abi_version };
    if (!std.mem.eql(u8, found.machine.name(), machine)) return .{ .machine = found.machine };
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
    // `lower.describeArtifact` writes `{ i64, i64, i64, i32, i32, i32,
    // i32, { i32, [52 x i8] } }`; if this struct moves, that must move
    // with it, and a loader reading a tag through the wrong offsets is
    // the exact failure the tag exists to prevent.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Artifact, "magic"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Artifact, "source_hash"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Artifact, "generator"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Artifact, "format"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(Artifact, "abi_version"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Artifact, "debug"));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(Artifact, "reserved"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(Artifact, "machine"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(Artifact, "machine") +
        @offsetOf(MachineName, "length"));
    try std.testing.expectEqual(@as(usize, 44), @offsetOf(Artifact, "machine") +
        @offsetOf(MachineName, "text"));
    // No padding anywhere: every field is where the one before it
    // ended, and the whole tag is ninety-six bytes a reader of raw
    // bytes can walk without a rule to remember.
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(Artifact));
}

test "a machine's name lives in the tag, not behind a pointer" {
    // The name has to survive being copied out of a file: a reader
    // holds bytes nobody relocated, so what it hands on must be the
    // whole answer and not a borrow of something still in the file.
    const named: MachineName = .of("aarch64-macos-none");
    try std.testing.expectEqualStrings("aarch64-macos-none", named.name());
    const copied = named;
    try std.testing.expectEqualStrings("aarch64-macos-none", copied.name());
    try std.testing.expectEqualStrings(machine, MachineName.here.name());
    // Unused bytes are zero rather than whatever the stack held, so
    // two tags for the same machine are the same ninety-six bytes.
    try std.testing.expectEqual(@as(u8, 0), named.text[named.length]);
    try std.testing.expectEqual(@as(u8, 0), named.text[machine_capacity - 1]);
}

test "an artifact tag is refused by name, in the order a loader checks" {
    const elsewhere = "sparc64-solaris-none";
    try std.testing.expect(!std.mem.eql(u8, machine, elsewhere));

    var good: Artifact = .{ .source_hash = 7, .debug = 1 };
    try std.testing.expectEqual(@as(?Mismatch, null), check(&good, 7));
    try std.testing.expectEqual(@as(?Mismatch, null), check(&good, null));
    try std.testing.expect(check(&good, 8).?.is(.source));
    try std.testing.expect(check(null, 7).?.is(.not_an_artifact));

    var wrong = good;
    wrong.machine = .of(elsewhere);
    // The refusal carries the artifact's own name, which is what lets
    // the sentence say which two machines are meant.
    try std.testing.expectEqualStrings(elsewhere, check(&wrong, 7).?.machine.name());
    wrong = good;
    wrong.generator = generator +% 1;
    try std.testing.expect(check(&wrong, 7).?.is(.generator));
    // A different generator is refused even when nobody asked about
    // the program, because it is a fact about the artifact and not
    // about the question: `loom run NAME.lc` names no program to match.
    try std.testing.expect(check(&wrong, null).?.is(.generator));
    // And it is the answer given first when the program changed too:
    // the toolchain moving under an artifact is the more fundamental
    // of the two, and the one a person will not otherwise guess.
    try std.testing.expect(check(&wrong, 8).?.is(.generator));
    wrong = good;
    wrong.abi_version = abi.version + 1;
    try std.testing.expectEqual(abi.version + 1, check(&wrong, 7).?.abi_version);
    wrong = good;
    wrong.format = format + 1;
    try std.testing.expectEqual(format + 1, check(&wrong, 7).?.format);
    wrong = good;
    wrong.magic = 0;
    try std.testing.expect(check(&wrong, 7).?.is(.not_an_artifact));

    // A tag that claims more name than it has room for is damaged
    // rather than a foreign machine: nothing this compiler writes can
    // say it, so there is no other side to name.
    wrong = good;
    wrong.machine.length = machine_capacity + 1;
    try std.testing.expect(check(&wrong, 7).?.is(.damaged));
    // And it is answered before the machine is compared, so no
    // sentence is ever built out of a length nobody can trust.
    wrong.abi_version = abi.version + 1;
    try std.testing.expect(check(&wrong, 7).?.is(.damaged));
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
