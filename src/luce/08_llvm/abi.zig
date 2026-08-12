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
//!
//! **What an artifact says about *itself* is not here.**  The tag a
//! loader reads — the machine, the code generator, the program the
//! artifact was built from, and which `version` below it was generated
//! against — is `08_llvm/artifact.zig`, and it carries a version number
//! of its own: a loader has to be able to read the tag before it can
//! believe the ABI version written in it, so the shape of the saying
//! and the thing said move on separate schedules.

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

// ---------------------------------------------------------------------------
// The version, and what a run answers
// ---------------------------------------------------------------------------

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
///
/// 9 — `key_read` can say the keyboard has run dry.  No field moved
/// and no signature changed; what changed is that `no` now *means*
/// something on `key_read`'s slot — end of input, which the program
/// meets as `none` — where before it was defined by the shared
/// `Answer` convention and read by nobody.  An artifact built against
/// the old reading asks again forever at the end of its input, so it
/// has to be rebuilt rather than tolerated.
///
/// 10 — a run can end because the program said so.  `Status` gains
/// `exited`, and one optional slot arrives at the end of the table:
/// `exited(status)`, called at the `exit(status)` site — before the
/// unwind, so the host records the number while the program is still
/// leaving — and fail-closed like every effect: a host without the
/// slot traps `host_unavailable` at the call.  No field moved.
///
/// 11 — a program can ask what machine it is on.  Three optional slots
/// arrive at the end of the table with one shape between them:
/// `os_total_memory`, `os_available_memory` and `os_cpu_count`, each
/// answering a number through an out-parameter under the usual
/// `Answer` convention.  Three at once and not one at a time, because
/// a version is a rebuild of every artifact there is and the machine's
/// facts are one subject; asking for them a release apart would spend
/// that three times over.  What is new is only what `no` *means* on
/// these slots — this host cannot tell — and that is the same refusal
/// a null slot gives, so the program traps `host_unavailable` at the
/// call either way and no host has to invent a number.  No field
/// moved.
///
/// 12 — **a file is bytes reached through an open handle**
/// (docs/BYTES.md).  Five slots arrive at the end of the table —
/// `handle_open`, `handle_read`, `handle_write`, `handle_flush`,
/// `handle_close` — carrying raw bytes with no opinion about encoding:
/// a read fills a buffer the caller owns and says how much landed, and
/// a write takes a buffer and a length.  With them, three things move
/// that are one movement:
///
///   * **UTF-8 validation leaves the host.**  `file_read` is now
///     open-read-close over the byte channel followed by
///     `libluce_rt`'s own validation, so the interpreter, a compiled
///     artifact, and every future host agree byte-for-byte on what
///     "not text" means — that sentence used to live in `apps/host.zig`
///     where only loom could say it.
///   * **The whole-file text slots retire from use.**  `file_read`,
///     `file_write` and `file_append` keep their positions and their
///     signatures — the table is append-only and nothing reorders —
///     but no artifact built at this version indexes them, and the
///     hosts in this tree leave them null.
///   * **The handle channel is installed once**, at the start of a
///     run, into `libluce_rt` rather than read at each call: a handle
///     is closed when its owning scope ends, and that release happens
///     inside the ownership walk where no generated code is standing.
///
/// One bump for the whole movement, because it is one movement: an
/// artifact built against the old reading calls a `file_read` slot the
/// host no longer fills, and must be rebuilt rather than tolerated.
/// 13 — threads (docs/THREADS.md D8).  Two slots, `worker_spawn` and
/// `worker_join`, appended: a host supplies threads and nothing else,
/// so the whole of concurrency's machine surface is "start this C
/// function on a thread" and "wait for it".  Both fail-closed; a host
/// that answers neither traps `host_unavailable` at the `spawn`.
/// 14 — `shell_run` is appended: a host can run one shell command,
/// capture its output and return it to a Luce program.  A command's
/// non-zero exit is data in the captured text; only failure to start
/// the shell answers `no` and becomes `io_failed`.
///
/// 15 — `term_event_data` is appended.  Terminal input still arrives
/// through the existing `key_read` slot; this number-only query exposes
/// the mouse coordinates, button, modifiers and wheel value belonging to
/// the event just read, plus zero for keyboard events.  No earlier field
/// moves, but the new intrinsic must not index an older table.
///
/// 16 — `dir_create` and `epoch_ms` are appended, in one bump for two
/// services because a version is a rebuild of every artifact there is
/// and paying that twice in a week buys nothing.  They are not one
/// subject, and this file says so rather than pretending: the first
/// makes a directory and the parents leading to it, answering `no` for
/// a world that refused; the second says what time it is, which
/// `clock_ms` cannot — that clock is monotonic with an unspecified
/// origin, so only its differences mean anything.  Both are optional
/// and fail-closed like every effect before them, and `epoch_ms`
/// answers through the `Answer` convention rather than as a bare
/// number for the reason the machine facts do: a host with no calendar
/// must be able to say so instead of inventing a number.  No earlier
/// field moves.
pub const version: u32 = 16;

/// The symbol a compiled Luce artifact exports for a loader to call.
/// What the thing being called *is* — the machine, the ABI version, the
/// program it holds — is the artifact's tag (`08_llvm/artifact.zig`).
pub const entry_symbol = "luce_main";

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
    /// The program said `exit(status)`.  Nothing is wrong and nothing
    /// failed; `Host.exited` was called with the status at the exit
    /// site, and the host maps it onto whatever its world calls one —
    /// on POSIX, the low eight bits of a process's exit code.
    exited = 4,
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

// ---------------------------------------------------------------------------
// The services, one typedef each
// ---------------------------------------------------------------------------

/// Console line output for `print`.  Optional: a null slot means the
/// service does not exist, and the program traps `host_unavailable`
/// rather than touching anything (`docs/V2.md`'s fail-closed rule).
/// Every service below is optional on the same terms.
///
/// **A host service must not unwind.**  Every callback in this table
/// returns normally or does not return at all (a host is free to
/// `exit`); throwing an exception or `longjmp`ing across `luce_main`
/// is undefined behavior.  Stated because generated Luce functions
/// are marked `nounwind`, and that claim is only honest if the hosts
/// they ultimately call into keep this rule — both hosts in this
/// tree do, being Zig with no exceptions (task #45's audit).
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

/// The program said `exit(status)`.  Called once, at the exit site
/// and before the unwind, so the host holds the number while the
/// program is still leaving; `luce_main` then returns `.exited`, and
/// the host acts on what it recorded.  Optional and fail-closed like
/// every effect: a null slot traps `host_unavailable` at the call,
/// because a host that cannot carry a status cannot honor an exit.
pub const ExitedFn = *const fn (
    context: ?*anyopaque,
    status: i64,
) callconv(.c) void;

/// One fact about the machine the program is running on, as a number:
/// bytes of physical memory, bytes of it still available, processors.
/// One typedef for all three, because they are one question asked
/// three ways and a reader who has learned one has learned them.
///
/// `yes` fills `answer`.  `no` means **this host cannot tell** — it is
/// on a platform whose numbers it does not know how to ask for, or the
/// ask failed — and the program then traps `host_unavailable`, exactly
/// as it would against a null slot.  That is the whole reason the
/// answer is not a bare `i64` like `clock_ms`: a host that does not
/// know how much memory the machine has must be able to say so, and
/// the alternative is inventing a number, which is a lie a program
/// cannot see through.  `exhausted` keeps its usual meaning.
///
/// A fact may be read more than once and answer differently: available
/// memory moves under the program's feet, which is what makes it worth
/// asking for. Nothing here is cached on the program's behalf.
pub const MachineFactFn = *const fn (
    context: ?*anyopaque,
    answer: *i64,
) callconv(.c) Answer;

/// Run one command through the host shell.  `yes` fills `text` and
/// `length` with captured stdout/stderr plus the command's exit status;
/// `no` means the shell itself could not be started and the program
/// raises `io_failed` for the command.  The bytes are borrowed for the
/// duration of the call, like every text out-parameter in this table.
pub const ShellRunFn = *const fn (
    context: ?*anyopaque,
    command: [*]const u8,
    command_length: i64,
    text: *[*]const u8,
    length: *i64,
) callconv(.c) Answer;

/// Read a whole file.  `yes` fills `text`/`length` with bytes borrowed
/// for the duration of the call; `no` means the read failed and the
/// program traps `file_read_failed`.
///
/// **Retired at version 12** (docs/BYTES.md R2), along with
/// `FileWriteFn` and `FileAppendFn`.  The slot keeps its position
/// because the table is append-only, but nothing calls it: `file_read`
/// is open-read-close over the handle channel plus `libluce_rt`'s own
/// UTF-8 validation, and the hosts in this tree leave the slot null.
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

/// Numeric data belonging to the most recent `key_read`: field 0 is the
/// zero-based row, 1 the zero-based column, 2 the mouse button, 3 the
/// modifier bits (shift=1, alt=2, ctrl=4), and 4 the wheel value.  Other
/// fields answer zero.  Keyboard events use the default values.
pub const TermEventDataFn = *const fn (
    context: ?*anyopaque,
    field: i64,
) callconv(.c) i64;

/// Block until one key arrives, and describe it: a stable name
/// ("text", "enter", "ctrl_s", ...) and the inserted text when the name
/// is "text".  Both are borrowed for the duration of the call.
///
/// `no` is **end of input** — no key will ever arrive, because the
/// pipe driving the program ended or the terminal closed — which the
/// program sees as `none`, exactly as `read_line` does off the same
/// descriptor.  Nothing there, and no reason worth carrying
/// (docs/FAILURE.md).  A host with no way to say it is a host whose
/// caller asks again forever, which is what this answer used to mean
/// by accident: it was defined and never read.
///
/// A host that answers `no` may leave the out-parameters untouched;
/// the generated code clears them first and reads them either way.
///
/// `key_text` has no slot of its own and needs none: it answers what
/// the last `key_read` carried, which the runtime remembers, so it
/// reaches nothing and a program that never read a key gets "".  End
/// of input clears it too — the payload of a key that never came is
/// "" and not the one before it.
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

/// Make a directory at `path`, **and every directory leading to it**.
/// `no` is the world saying no, which the program meets as
/// `io_failed`.
///
/// Two rules a host must keep, both of them the caller's whole reason
/// for calling:
///
///   * **The parents are made too** (`mkdir -p`).  The callers are a
///     package store laying out `.luce/packages/NAME-VERSION/` and an
///     extractor writing under a directory the archive named and
///     nobody made; a one-component-at-a-time service puts the same
///     splitting loop in every program.
///   * **A directory already there is `yes`.**  The call means "there
///     is a directory at this path when I return", and answering `no`
///     would make every caller write an existence check in front of
///     it — which is a race, and the same one `file_exists` in front
///     of `file_read` is (docs/FAILURE.md).
///
/// A *file* holding the name is still `no`: the caller asked for a
/// directory and there is not one.
pub const DirCreateFn = *const fn (
    context: ?*anyopaque,
    path: [*]const u8,
    path_length: i64,
) callconv(.c) Answer;

/// Milliseconds since the Unix epoch — what time it is, as distinct
/// from `clock_ms`'s "how much time has passed".
///
/// `yes` fills `answer`.  `no` means **this host cannot tell**: it has
/// no calendar, or is deliberately running the program without one,
/// and the program then traps `host_unavailable` exactly as it would
/// against a null slot.  That is why this is not a bare `i64` like
/// `ClockFn`: a monotonic reading may have any origin at all and every
/// host can produce one, while there is no honest wall-clock number
/// for a host that does not know the date, and inventing one is a lie
/// a program cannot see through (`apps/machine.zig`'s rule).
///
/// It is **not monotonic**, deliberately: an operator may set the
/// clock, and a program timing something wants `clock_ms`.
pub const EpochFn = *const fn (
    context: ?*anyopaque,
    answer: *i64,
) callconv(.c) Answer;

// ---------------------------------------------------------------------------
// The handle channel (version 12)
// ---------------------------------------------------------------------------
//
// The C shape, deliberately: a read fills a buffer the caller owns and
// answers the count, a write takes a buffer and a length
// (docs/BYTES.md R4).  Nothing here has an opinion about encoding —
// text is a validation `libluce_rt` performs on the bytes — and nothing
// here is path-addressed after the open, which is what makes the same
// five slots serve a socket when `std.network` arrives.
//
// **These are the only file slots a version-12 artifact indexes.**  The
// runtime is handed them once, at the start of a run, because a
// handle's close happens at a scope's end where no generated code is
// standing (`runtime/files.zig`).

/// Open `path` and answer the number the host will know it by.  `mode`
/// is `runtime.files.Mode`: 0 read, 1 write (create and truncate), 2
/// append (create, write at the end).  A host that does not recognise a
/// mode says no, which the program meets as `io_failed`.
pub const HandleOpenFn = *const fn (
    context: ?*anyopaque,
    path: [*]const u8,
    path_length: i64,
    mode: i64,
    handle: *i64,
) callconv(.c) Answer;

/// Fill `into` with at most `capacity` bytes and say how many landed.
/// **Zero with a `yes` is the end of the file**, which is the whole
/// reason the count is answered rather than the buffer being assumed
/// full: a short read is ordinary and a program loops on it.
pub const HandleReadFn = *const fn (
    context: ?*anyopaque,
    handle: i64,
    into: [*]u8,
    capacity: i64,
    filled: *i64,
) callconv(.c) Answer;

/// Write `length` bytes and say how many landed.  A short write is not
/// a failure either; the caller loops.
pub const HandleWriteFn = *const fn (
    context: ?*anyopaque,
    handle: i64,
    from: [*]const u8,
    length: i64,
    written: *i64,
) callconv(.c) Answer;

/// `handle_flush` and `handle_close`, which take a handle and nothing
/// else.  A close is called from the ownership walk, which has nobody
/// to report to, so its answer is read by nothing: a host that cannot
/// close has already lost the file.
pub const HandlePlainFn = *const fn (
    context: ?*anyopaque,
    handle: i64,
) callconv(.c) Answer;

/// The service table handed to `luce_main`.
///
/// The struct is `extern` so its layout is the C layout the generated
/// code assumes: `context` first, then one pointer-sized slot per
/// service in declaration order.  `Slot` names those positions once so
/// the lowering and this struct cannot drift.
// ---------------------------------------------------------------------------
// The table itself
// ---------------------------------------------------------------------------

/// Start `body(argument)` on a thread of its own and answer the number
/// this host will know that thread by (docs/THREADS.md D8).
///
/// The host is told nothing about Luce: what runs is a C function, and
/// what it is handed is a pointer whose meaning is `libluce_rt`'s.
/// That is deliberate — a machine's contribution here is a thread, and
/// a host that grew an opinion about workers would be a second place
/// the concurrency model lived.
pub const WorkerSpawnFn = *const fn (
    context: ?*anyopaque,
    body: *const fn (argument: ?*anyopaque) callconv(.c) void,
    argument: ?*anyopaque,
    thread: *i64,
) callconv(.c) Answer;

/// Wait for a thread this host started to end.  `yes` when it has;
/// the caller does not read a `no`, because a host that cannot join
/// has already lost the thread and there is nobody left to tell.
pub const WorkerJoinFn = *const fn (context: ?*anyopaque, thread: i64) callconv(.c) Answer;

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
    /// Version 10: the program's chosen end, appended like everything
    /// before it so no field moves.
    exited: ?ExitedFn = null,
    /// Version 11: the machine's own facts, behind `std.os`.  Bytes,
    /// bytes, and a count — appended in one run, for one subject.
    os_total_memory: ?MachineFactFn = null,
    os_available_memory: ?MachineFactFn = null,
    os_cpu_count: ?MachineFactFn = null,
    /// Version 12: the handle channel (docs/BYTES.md).  Five slots for
    /// one subject, appended in one run for the reason the machine
    /// facts were: a version is a rebuild of every artifact there is,
    /// and a channel that arrived a slot at a time would spend that
    /// five times over.  All optional and fail-closed; a program given
    /// none of them computes and touches no file.
    handle_open: ?HandleOpenFn = null,
    handle_read: ?HandleReadFn = null,
    handle_write: ?HandleWriteFn = null,
    handle_flush: ?HandlePlainFn = null,
    handle_close: ?HandlePlainFn = null,
    /// Version 13: threads (docs/THREADS.md D8).  Two slots and no
    /// more, because a machine's whole contribution to concurrency is
    /// a thread: start this function on one, wait for it to end.
    /// Everything else a worker is — a runtime of its own, the
    /// arguments moved into it, the join, the census — is the
    /// language's, and none of it is a machine's business.
    ///
    /// Fail-closed like every other service: a host that answers
    /// neither traps `host_unavailable` at the `spawn`, which is the
    /// same sentence a host with no `print` says at a `print`.
    worker_spawn: ?WorkerSpawnFn = null,
    worker_join: ?WorkerJoinFn = null,
    /// Version 14: one host-shell command, captured as text. Appended
    /// so every earlier table field keeps its address.
    shell_run: ?ShellRunFn = null,
    /// Version 15: numeric data for the most recent terminal input event.
    term_event_data: ?TermEventDataFn = null,
    /// Version 16: a directory made with its parents, and the wall
    /// clock `clock_ms` deliberately is not.  Appended together, so
    /// every earlier field keeps its address; unrelated to each other,
    /// which the version note above says out loud rather than
    /// inventing a subject the two share.
    dir_create: ?DirCreateFn = null,
    epoch_ms: ?EpochFn = null,
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
    exited = 28,
    os_total_memory = 29,
    os_available_memory = 30,
    os_cpu_count = 31,
    handle_open = 32,
    handle_read = 33,
    handle_write = 34,
    handle_flush = 35,
    handle_close = 36,
    worker_spawn = 37,
    worker_join = 38,
    shell_run = 39,
    term_event_data = 40,
    dir_create = 41,
    epoch_ms = 42,

    pub const count = @typeInfo(Slot).@"enum".fields.len;
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "the slot table matches the struct layout" {
    inline for (@typeInfo(Slot).@"enum".fields) |field| {
        try std.testing.expectEqual(
            @as(usize, field.value) * @sizeOf(usize),
            @offsetOf(Host, field.name),
        );
    }
    try std.testing.expectEqual(@as(usize, Slot.count) * @sizeOf(usize), @sizeOf(Host));
}

test "the host's trap callback is the runtime's reporter, not a copy of it" {
    const runtime = @import("../runtime.zig");
    try std.testing.expect(TrapFn == runtime.trace.ReportFn);
    try std.testing.expect(RaisedFn == runtime.trace.ErrorReportFn);
    try std.testing.expect(TraceFrame == runtime.trace.Frame);
}
