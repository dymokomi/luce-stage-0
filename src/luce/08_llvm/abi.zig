//! The published Luce host ABI — the contract between a compiled
//! Luce artifact and whatever loads it (loom, a test, an embedder).
//!
//! A compiled artifact exports exactly one symbol, `luce_main`:
//!
//! ```c
//! int32_t luce_main(const LuceHost *host);
//! ```
//!
//! It returns `0` when the program ran to completion, `1` when it
//! trapped, `2` when the runtime ran out of memory, and `3` when an
//! error reached the top uncaught — a trap and an error being two
//! different sentences about a program (docs/FAILURE.md), which is why
//! they are two numbers and not one.  `Status` below is authoritative;
//! `apps/host.zig` maps them onto the exit statuses a runner returns.
//! Every *effect*
//! the program needs reaches the outside world through the `LuceHost`
//! table passed in — the artifact declares no undefined symbols beyond
//! `libluce_rt`, which it links statically.  That is deliberate: an
//! undefined `luce_host_print` does not link into a two-level-namespace
//! macOS dylib, and a vtable is the same shape `interpreter.Host` already
//! has for the interpreter.
//!
//! Effects come through this table; *semantics* do not.  Lists, maps,
//! strings, ownership, and the conversions are `libluce_rt` calls, not
//! host calls, because they are the language rather than a capability
//! the host may withhold (docs/CODEGEN.md).
//!
//! Compatibility rules for this file:
//!
//!   * Fields are append-only and never reordered.  Their order is the
//!     memory layout the generated code indexes with `getelementptr`.
//!   * Any change to an existing field's meaning or signature bumps
//!     `version`.
//!   * A host that supplies a table built for an older `version` must
//!     be refused by the loader, not tolerated.

const std = @import("std");
const builtin = @import("builtin");

/// One number computed by `build.zig` and compiled into both binaries:
/// what produced an artifact's machine code (`generator` below).
const build_options = @import("build_options");

/// The trap channel's C shapes, taken from the one file that defines
/// them.  Deliberately `runtime/trace.zig` and not the `runtime.zig`
/// barrel: the barrel force-analyzes the whole `luce_rt_*` C surface,
/// and a *host* — a loader, a standalone program's `main` — needs this
/// contract without dragging a second copy of the runtime library in
/// behind it.  `trace.zig` imports nothing but `std`.
const trace = @import("../runtime/trace.zig");

/// The ABI version a compiled artifact was built against.  Bumped
/// whenever a field's meaning or signature changes.
///
/// 2 — `str_int` left the table for `libluce_rt`, where a pure
/// conversion belongs, and `finished` arrived to carry the leak census.
///
/// 3 — the remaining host services arrived (files, arguments, the
/// terminal), and with them the one answer every service now gives:
/// `print` returns an `Answer` where it used to return nothing.
///
/// 4 — a trap became a whole trap.  `trap` now carries the call trace
/// as well as the code and the words, and is called once when the
/// program has stopped rather than at the site, because the trace does
/// not exist until unwinding is over (`runtime/trace.zig`).  The
/// `call_depth` service arrived with it: how many Luce frames the host
/// allows, which is what makes runaway recursion a `call_depth_exceeded`
/// trap on this path instead of a native stack overflow.
///
/// 5 — the artifact tag names its machine the way Zig names one rather
/// than the way LLVM does.  Same field, same layout, different string:
/// `machine` below is a compile-time constant, so a loader answers
/// "is this artifact mine?" without libLLVM in the process.
///
/// 6 — short text lives inside a `LuceValue`.  The tag is one byte
/// where it was eight, and the twenty-two bytes that frees are where a
/// String's text goes when it fits (docs/STRINGS.md).  No field moved
/// and nothing was reordered — `bits` and `length` are still at 8 and
/// 16 — but generated code reads a `Value` differently, so an artifact
/// built against the old reading has to be rebuilt.
///
/// 7 — a run can end a third way.  `luce_main` answers `errored` for a
/// program that raised something nobody caught, and `raised` arrived
/// beside `trap` to say what it was.  Required, like `trap`: a host
/// that can run a program has to be able to say why it stopped, and
/// the two reasons are different sentences.
///
/// 8 — the host surface closed.  Nine services arrived at the end of
/// the table, all optional and fail-closed like every one before them:
/// a line of standard input with the prompt that precedes it, a line
/// of standard error, a monotonic clock and a wait, one environment
/// variable, and the four file operations `file_read` and `file_write`
/// had left out.  No field moved; a run that never calls one pays
/// nothing.  A program *can* now be written, which is what the version
/// buys.
pub const version: u32 = 8;

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

/// The two symbols a compiled Luce artifact exports: what to call, and
/// what the thing being called is.
pub const entry_symbol = "luce_main";
pub const artifact_symbol = "luce_artifact";

/// The layout version of `Artifact` itself.  Separate from `version`
/// because a loader has to read the tag *before* it can believe
/// anything else in it: the tag says what the artifact is, and if the
/// shape of the saying changes, an old loader must refuse rather than
/// misread the fields after it.
///
/// 2 — `generator` arrived at the end, so an artifact says which code
/// generator wrote it and not only which program it holds.
pub const artifact_format: u32 = 2;

/// `LUCEART\0`, little-endian — the first eight bytes of the tag, so a
/// symbol of the right name but the wrong provenance is caught too.
pub const artifact_magic: u64 = 0x0054524145_43554c;

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
    magic: u64 = artifact_magic,
    /// `artifact_format` at the time it was written.
    format: u32 = artifact_format,
    /// The `version` of the host ABI the code was generated against.
    /// A loader must refuse anything but its own.
    abi_version: u32 = version,
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
pub fn checkArtifact(tag: ?*const Artifact, expect_hash: ?u64) ?Mismatch {
    const found = tag orelse return .not_an_artifact;
    if (found.magic != artifact_magic) return .not_an_artifact;
    if (found.format != artifact_format) return .format;
    if (found.abi_version != version) return .abi_version;
    const named = found.machine[0..@intCast(found.machine_length)];
    if (!std.mem.eql(u8, named, machine)) return .machine;
    if (found.generator != generator) return .generator;
    if (expect_hash) |wanted| {
        if (found.source_hash != wanted) return .source;
    }
    return null;
}

/// What `luce_main` returns.  The same four answers `libluce_rt`'s
/// `luce_rt_status` gives, because that is where they come from.
pub const Status = enum(i32) {
    /// The program ran to completion.
    ok = 0,
    /// The program trapped; `Host.trap` was called with the details.
    trapped = 1,
    /// The runtime could not get memory.  Nothing about the program
    /// was wrong, so this is not a trap.
    exhausted = 2,
    /// The program ended with an error nobody caught; `Host.raised`
    /// was called with the details.
    ///
    /// **Three, and not two.**  docs/FAILURE.md said "1 is trapped, 2
    /// becomes errored", and by the time errors were built 2 had been
    /// `exhausted` for two ABI versions.  Renumbering a published
    /// answer would have changed what every existing loader believes,
    /// so the new one took the next free number.
    errored = 3,
    _,
};

/// The C signature of `luce_main`.
pub const Entry = *const fn (host: *const Host) callconv(.c) Status;

/// What every host service answers.  One convention for all of them,
/// so generated code checks the same two things at every call site.
///
/// Strings a service hands back travel through out-parameters and are
/// borrowed for the duration of the call only: the generated code
/// copies them into the run's arena before the host can reuse the
/// storage.
pub const Answer = enum(i32) {
    /// The host could not get memory.  Nothing about the program was
    /// wrong, so this is not a trap: the run ends `exhausted`, the same
    /// answer the runtime library gives when its arena gives up.
    exhausted = -1,
    /// The service says no — the file could not be read, the argument
    /// index is out of range.  What that means is the caller's to
    /// decide; a service whose only job is an effect never answers it.
    no = 0,
    /// Done.  Anything produced is in the out-parameters.
    yes = 1,
    _,
};

/// Console line output for `print`.  Optional: a null slot means the
/// service does not exist, and the program traps `host_unavailable`
/// rather than touching anything (`docs/V2.md`'s fail-closed rule).
/// Every service below is optional on the same terms.
pub const PrintFn = *const fn (
    context: ?*anyopaque,
    text: [*]const u8,
    length: i64,
) callconv(.c) Answer;

/// Report a trap.  Called once, when the program has stopped and
/// immediately before `luce_main` returns `.trapped`.  `code` is the
/// numeric value of `mir.TrapCode`; the message, the frames, and the
/// text inside them are borrowed for the duration of the call only.
///
/// Not at the trap site, which is where it used to be: a trap carries
/// its call trace, and the trace does not exist until the program has
/// finished unwinding.  Every frame records itself on the way out and
/// the finished trace arrives here with the trap it belongs to, rather
/// than the host being told half of it twice (`runtime/trace.zig`).
///
/// `dropped` counts the frames the trace's cap cut, so a runaway
/// recursion reports its innermost calls and a number, not a wall of
/// text.
///
/// Required: unlike the effect services this is part of the runtime
/// contract, not a capability, and `luce_main` calls it without a null
/// check.  A trap raised inside `libluce_rt` and one raised inline by
/// generated code arrive here by the same door.
pub const TrapFn = trace.ReportFn;

/// One call in a trap's trace, innermost first.  A `--release`
/// artifact reports line and column zero and still names the function.
pub const TraceFrame = trace.Frame;

/// Report an uncaught error.  Called once, when the program has
/// stopped and immediately before `luce_main` returns `.errored`.
/// `code` is the numeric value of `mir.ErrorCode`; the message and the
/// origin are borrowed for the duration of the call.
///
/// **One position, not a trace** (docs/FAILURE.md).  `origin` is where
/// the error was raised, recorded once at the raise.  A trap carries
/// the whole stack because a trap is a bug and the stack is the
/// diagnosis; an error is news, and where it came from is the news.
///
/// Required, on the same terms as `trap`: this is the runtime
/// contract, not a capability, and `luce_main` calls it without a null
/// check.
pub const RaisedFn = trace.ErrorReportFn;

/// How many nested Luce calls the host allows before the program traps
/// `call_depth_exceeded`.  Optional: a null slot means
/// `default_call_depth`.
///
/// This is the same policy limit the interpreter takes as
/// `interpreter.Budget.call_depth`, and it exists for the same reason.
/// Luce promises that runaway recursion is a trap with a message and a
/// trace, never a native stack overflow — so somebody has to say how
/// deep is too deep, and it is the host, which is the only party that
/// knows how much stack it has.  Answering an absurd number does not
/// make the promise stronger: the machine's own stack is still finite,
/// and a limit above what it can hold is a limit that never fires.
pub const CallDepthFn = *const fn (context: ?*anyopaque) callconv(.c) i64;

/// The depth a host that says nothing gets.  Identical to
/// `interpreter.Budget.call_depth`, so a program that recurses too far
/// traps at the same call on both engines.
pub const default_call_depth: i64 = 256;

/// The run ended without trapping, leaving `leaked` objects alive.
/// Memory is explicit in Luce, so what a program did not free is part
/// of what it did, and a host that wants to say so reads it here.
/// Optional: a null slot simply means nobody is counting.
pub const FinishedFn = *const fn (
    context: ?*anyopaque,
    leaked: i64,
) callconv(.c) void;

/// Read a whole file.  `yes` fills `text`/`length` with bytes borrowed
/// for the duration of the call; `no` means the read failed and the
/// program traps `file_read_failed`.
pub const FileReadFn = *const fn (
    context: ?*anyopaque,
    path: [*]const u8,
    path_length: i64,
    text: *[*]const u8,
    length: *i64,
) callconv(.c) Answer;

/// Write a whole file.  `no` is the answer `file_write` gives the
/// program as `false`, not a trap: a program may ask whether a write
/// worked.
pub const FileWriteFn = *const fn (
    context: ?*anyopaque,
    path: [*]const u8,
    path_length: i64,
    content: [*]const u8,
    content_length: i64,
) callconv(.c) Answer;

/// Whether a file exists.  `no` is the program-visible `false`.
pub const FileExistsFn = *const fn (
    context: ?*anyopaque,
    path: [*]const u8,
    path_length: i64,
) callconv(.c) Answer;

/// How many program arguments there are.  Cannot fail, so it answers
/// the count directly rather than an `Answer`.
pub const ArgCountFn = *const fn (context: ?*anyopaque) callconv(.c) i64;

/// One program argument, borrowed for the duration of the call.  `no`
/// means the index is out of range and the program traps
/// `argument_bounds`.
pub const ArgFn = *const fn (
    context: ?*anyopaque,
    index: i64,
    text: *[*]const u8,
    length: *i64,
) callconv(.c) Answer;

/// The screen's size.  Cannot fail: a host with no real terminal
/// answers whatever it considers the window to be.
pub const TermSizeFn = *const fn (context: ?*anyopaque) callconv(.c) i64;

/// `term_clear` and `term_flush`, which take nothing and only ever
/// answer `yes` or `exhausted`.
pub const TermPlainFn = *const fn (context: ?*anyopaque) callconv(.c) Answer;

pub const TermMoveFn = *const fn (
    context: ?*anyopaque,
    row: i64,
    col: i64,
) callconv(.c) Answer;

pub const TermStyleFn = *const fn (
    context: ?*anyopaque,
    foreground: i64,
    background: i64,
    bold: i32,
) callconv(.c) Answer;

pub const TermWriteFn = *const fn (
    context: ?*anyopaque,
    text: [*]const u8,
    length: i64,
) callconv(.c) Answer;

/// Block until one key arrives, and describe it: a stable name
/// ("text", "enter", "ctrl_s", ...) and the inserted text when the name
/// is "text".  Both are borrowed for the duration of the call.
///
/// `key_text` has no slot of its own and needs none: it answers what
/// the last `key_read` carried, which the runtime remembers, so it
/// reaches nothing and a program that never read a key gets "".
pub const KeyReadFn = *const fn (
    context: ?*anyopaque,
    name: *[*]const u8,
    name_length: *i64,
    text: *[*]const u8,
    text_length: *i64,
) callconv(.c) Answer;

/// Read one line of standard input, having first written `prompt` and
/// flushed it.
///
/// **The prompt is an argument and not a separate service**, for the
/// reason `key_read` presents the pending frame before it blocks: a
/// prompt that is not on the screen when the program stops for input
/// is a program that looks hung.  Making the host write it puts the
/// ordering where the buffering is.  The prompt is host-written text
/// and is sanitized like any other.
///
/// `yes` fills `text`/`length` with the line, its newline already
/// removed, borrowed for the duration of the call.  `no` is end of
/// input, which the program sees as `none` — nothing there, and no
/// reason worth carrying (docs/FAILURE.md).
pub const ReadLineFn = *const fn (
    context: ?*anyopaque,
    prompt: [*]const u8,
    prompt_length: i64,
    text: *[*]const u8,
    length: *i64,
) callconv(.c) Answer;

/// One environment variable.  `no` means unset, which is again `none`
/// rather than a failure: "nobody set it" is the same fact every time.
pub const EnvFn = *const fn (
    context: ?*anyopaque,
    name: [*]const u8,
    name_length: i64,
    text: *[*]const u8,
    length: *i64,
) callconv(.c) Answer;

/// Milliseconds on a monotonic clock.  Cannot fail, so it answers the
/// reading directly.  The origin is unspecified and only differences
/// mean anything — a host free to answer "since this process started"
/// is a host that needs no calendar.
pub const ClockFn = *const fn (context: ?*anyopaque) callconv(.c) i64;

/// Wait at least `milliseconds`.  A duration that has already elapsed
/// — zero, or a negative one out of `deadline - now` — is not an
/// error and not a bug: there is no time left to wait, so the call
/// returns.  Only `exhausted` is ever answered besides `yes`.
pub const SleepFn = *const fn (
    context: ?*anyopaque,
    milliseconds: i64,
) callconv(.c) Answer;

/// Append to a file, creating it if it is not there.  `no` is the
/// world saying no, which the program meets as `io_failed`.
pub const FileAppendFn = *const fn (
    context: ?*anyopaque,
    path: [*]const u8,
    path_length: i64,
    content: [*]const u8,
    content_length: i64,
) callconv(.c) Answer;

/// Remove a file.  `no` on anything that left the file there,
/// including "it was never there" — the host cannot tell those apart
/// and neither can `Answer` (docs/FAILURE.md).
pub const FileDeleteFn = *const fn (
    context: ?*anyopaque,
    path: [*]const u8,
    path_length: i64,
) callconv(.c) Answer;

/// Rename a file.  `no` if it did not happen, whatever the reason.
pub const FileRenameFn = *const fn (
    context: ?*anyopaque,
    from: [*]const u8,
    from_length: i64,
    to: [*]const u8,
    to_length: i64,
) callconv(.c) Answer;

/// The names in a directory, **NUL-separated** in one borrowed buffer,
/// without `.` or `..`.
///
/// One buffer rather than a vector, because that is the only shape
/// this table carries: every service that hands text back hands back
/// bytes and a length, and inventing a second convention for one
/// service would mean a second thing for a host author to get right.
/// NUL is the separator because it is the one byte a file name may not
/// contain on any system this runs on, so the joining loses nothing.
/// An empty buffer is an empty directory.
pub const DirListFn = *const fn (
    context: ?*anyopaque,
    path: [*]const u8,
    path_length: i64,
    names: *[*]const u8,
    names_length: *i64,
) callconv(.c) Answer;

/// The service table handed to `luce_main`.
///
/// The struct is `extern` so its layout is the C layout the generated
/// code assumes: `context` first, then one pointer-sized slot per
/// service in declaration order.  `Slot` names those positions once so
/// the lowering and this struct cannot drift.
pub const Host = extern struct {
    /// Opaque host state, passed back to every callback.
    context: ?*anyopaque = null,
    /// Optional — a null slot traps `host_unavailable`.
    print: ?PrintFn = null,
    /// Required.
    trap: TrapFn,
    /// Optional — the leak census, reported once at the end of a run
    /// that did not trap.
    finished: ?FinishedFn = null,
    file_read: ?FileReadFn = null,
    file_write: ?FileWriteFn = null,
    file_exists: ?FileExistsFn = null,
    arg_count: ?ArgCountFn = null,
    arg: ?ArgFn = null,
    term_rows: ?TermSizeFn = null,
    term_cols: ?TermSizeFn = null,
    term_clear: ?TermPlainFn = null,
    term_move: ?TermMoveFn = null,
    term_style: ?TermStyleFn = null,
    term_write: ?TermWriteFn = null,
    term_flush: ?TermPlainFn = null,
    key_read: ?KeyReadFn = null,
    /// Optional — a null slot means `default_call_depth`.  Not an
    /// effect: a policy the host sets, like the interpreter's budget.
    call_depth: ?CallDepthFn = null,
    /// Required — the other way a run can end (docs/FAILURE.md).
    /// Appended rather than placed beside `trap`, because every field
    /// before it keeps the offset it had.
    raised: RaisedFn,
    /// The nine that arrived at version 8, appended in one run for the
    /// same reason as everything above them: a field that never moves
    /// is a loader that never has to guess.  All optional, all
    /// fail-closed.
    read_line: ?ReadLineFn = null,
    print_error: ?PrintFn = null,
    clock_ms: ?ClockFn = null,
    sleep_ms: ?SleepFn = null,
    env: ?EnvFn = null,
    file_append: ?FileAppendFn = null,
    file_delete: ?FileDeleteFn = null,
    file_rename: ?FileRenameFn = null,
    dir_list: ?DirListFn = null,
};

/// The index of each `Host` field, as the generated code addresses it.
/// `getelementptr` walks a struct of `count` pointers with these
/// indices, so the order here is the memory layout above.
pub const Slot = enum(u32) {
    context = 0,
    print = 1,
    trap = 2,
    finished = 3,
    file_read = 4,
    file_write = 5,
    file_exists = 6,
    arg_count = 7,
    arg = 8,
    term_rows = 9,
    term_cols = 10,
    term_clear = 11,
    term_move = 12,
    term_style = 13,
    term_write = 14,
    term_flush = 15,
    key_read = 16,
    call_depth = 17,
    raised = 18,
    read_line = 19,
    print_error = 20,
    clock_ms = 21,
    sleep_ms = 22,
    env = 23,
    file_append = 24,
    file_delete = 25,
    file_rename = 26,
    dir_list = 27,

    pub const count = @typeInfo(Slot).@"enum".fields.len;
};

test "the slot table matches the struct layout" {
    inline for (@typeInfo(Slot).@"enum".fields) |field| {
        try std.testing.expectEqual(
            @as(usize, field.value) * @sizeOf(usize),
            @offsetOf(Host, field.name),
        );
    }
    try std.testing.expectEqual(@as(usize, Slot.count) * @sizeOf(usize), @sizeOf(Host));
}

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
    // Appended at `artifact_format` 2, which is what that bump was:
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
    try std.testing.expectEqual(@as(?Mismatch, null), checkArtifact(&good, 7));
    try std.testing.expectEqual(@as(?Mismatch, null), checkArtifact(&good, null));
    try std.testing.expectEqual(Mismatch.source, checkArtifact(&good, 8).?);
    try std.testing.expectEqual(Mismatch.not_an_artifact, checkArtifact(null, 7).?);

    var wrong = good;
    wrong.machine = elsewhere.ptr;
    wrong.machine_length = elsewhere.len;
    try std.testing.expectEqual(Mismatch.machine, checkArtifact(&wrong, 7).?);
    wrong = good;
    wrong.generator = generator +% 1;
    try std.testing.expectEqual(Mismatch.generator, checkArtifact(&wrong, 7).?);
    // A different generator is refused even when nobody asked about
    // the program, because it is a fact about the artifact and not
    // about the question: `loom run NAME.lc` names no program to match.
    try std.testing.expectEqual(Mismatch.generator, checkArtifact(&wrong, null).?);
    // And it is the answer given first when the program changed too:
    // the toolchain moving under an artifact is the more fundamental
    // of the two, and the one a person will not otherwise guess.
    try std.testing.expectEqual(Mismatch.generator, checkArtifact(&wrong, 8).?);
    wrong = good;
    wrong.abi_version = version + 1;
    try std.testing.expectEqual(Mismatch.abi_version, checkArtifact(&wrong, 7).?);
    wrong = good;
    wrong.format = artifact_format + 1;
    try std.testing.expectEqual(Mismatch.format, checkArtifact(&wrong, 7).?);
    wrong = good;
    wrong.magic = 0;
    try std.testing.expectEqual(Mismatch.not_an_artifact, checkArtifact(&wrong, 7).?);
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

test "the host's trap callback is the runtime's reporter, not a copy of it" {
    const runtime = @import("../runtime.zig");
    try std.testing.expect(TrapFn == runtime.trace.ReportFn);
    try std.testing.expect(RaisedFn == runtime.trace.ErrorReportFn);
    try std.testing.expect(TraceFrame == runtime.trace.Frame);
}
