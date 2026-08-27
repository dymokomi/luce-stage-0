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
//! Pre-1.0 change rules for this file:
//!
//!   * Field order is the memory layout generated code indexes with
//!     `getelementptr`; every producer, consumer, and `Slot` moves together.
//!   * Any layout, meaning, or signature change bumps `version`.
//!   * Older versions are refused. There are no adapters, tombstones, or
//!     migration paths added solely to keep a pre-1.0 artifact running.
//!
//! **What an artifact says about *itself* is not here.**  The tag a
//! loader reads — the machine, the code generator, the program the
//! artifact was built from, and which `version` below it was generated
//! against — is `codegen/artifact.zig`, and it carries a version number
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
/// `str` text goes when it fits (docs/STRINGS.md). No field moved
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
///
/// 17 — `path_kind` is appended, and `file_exists` retires from use
/// (docs/FILESYSTEM.md D16).  One slot for one subject, and the
/// subject is a question the boundary could not previously ask: *what
/// is at this path*.  `file_exists` could only answer yes or no, and
/// it answered `false` for both "nothing is there" and "I was not
/// allowed to look" — two different facts with one bit between them,
/// which is the shape docs/FAILURE.md refuses.  `path_kind` widens the
/// *payload* rather than the `Answer`: `yes` fills a kind code — 0
/// nothing, 1 file, 2 directory, 3 other — and `no` is the world
/// refusing to say, which the program meets as `io_failed`.  Inventing
/// a fourth `Answer` for "there is nothing there" would have changed
/// what `Answer` means at every other slot, and absence is not a
/// refusal.
///
/// Links are **followed**: the kind is the kind of the thing the path
/// names, which is what `handle_open`, `file_delete` and `file_rename`
/// already mean, so a dangling link is 0 and not a fourth code.
///
/// `file_exists` keeps its position and its signature — the table is
/// append-only and nothing reorders — but no artifact built at this
/// version indexes it, and the hosts in this tree leave it null,
/// exactly as the whole-file text slots were left at version 12.
///
/// 18 — `finished` keeps its shape and position, but its census now
/// covers every run that opened a runtime: normal return, `exit`, a
/// trap, and an uncaught error.  Only exhaustion has no runtime to
/// count.  Hosts that use the number to diagnose a run must rebuild
/// with this meaning rather than treating a missing callback as zero.
///
/// 19 — the backend-neutral window/GPU channel arrived.  The eight
/// optional slots at the end describe backend selection, window creation,
/// a window's surface, surface dimensions, three drawing operations, and
/// native-resource close.  Nothing before them moved.  The callbacks carry
/// native handles as opaque `i64`s; the language owns them through the same
/// resource walk as files, while Metal/Vulkan policy remains in the host.
///
/// 20 — explicit numeric widths complete the value channel. Four runtime
/// tags (`i8`, `u16`, `u32`, `u64`) and four packed container element kinds
/// are appended; every existing numeric tag retains its value. Generated
/// code now boxes, unboxes, compares, hashes, and stores each of the eight
/// integer widths with exact-type arithmetic, so artifacts built
/// against the old reading must be rebuilt.
///
/// 21 — `char` and `bytes` append two runtime value tags, packed character
/// cells append their element kind, and generated code may call the new
/// immutable-byte conversion service. The 24-byte `Value` layout is
/// unchanged; hosts still rebuild because the appended tags are new ABI
/// vocabulary.
///
/// 22 — zeroing weak storage appends the `weak` runtime tag and the
/// `luce_rt_weak_store`/`luce_rt_weak_load` services. `Value` remains 24
/// bytes, but generated code and the runtime must agree on the new tag and
/// upgrade protocol.
///
/// 23 — nominal class instances add three runtime services for consuming
/// construction, borrowed field reads, and shared in-place field writes.
/// The value representation stays an ordinary ARC object handle.
///
/// 24 — the pre-1.0 table is compacted. Four services already replaced by
/// the byte-handle channel (`file_read`, `file_write`, `file_append`, and
/// `file_exists`) leave the layout instead of surviving as null tombstones.
///
/// 25 — the transport channel arrives (docs/NETWORK.md): `socket_connect`,
/// `socket_listen`, `socket_accept`, `socket_port`, and `socket_close`,
/// appended together in one bump.  Connected sockets travel the existing
/// `handle_read`/`handle_write`/`handle_flush` slots unchanged.  The five
/// new callbacks block for a peer, run outside the Effects guard, and are
/// therefore required to be thread-safe — the one place the table's
/// concurrency contract is stronger than "never entered concurrently".
///
/// When this number moves, move the sentence below with it — the two
/// must change together so concurrent ABI changes meet as a merge
/// conflict here instead of silently sharing one version number.
/// This comment last moved for version 25.
pub const version: u32 = 30;
// 26 — the clipboard (docs/STD.md): one slot, `term_copy`, at the end
// of the table.  A terminal host emits OSC 52 so the surrounding
// terminal owns what "the system clipboard" means over SSH and mux.
// 27 — the process's own streams and a fed subprocess: one slot,
// `standard_stream`, answering stdin/stdout/stderr as ordinary
// handles, and `shell_run` grows an input the host feeds the child —
// the two capabilities a tool that speaks a protocol over stdio (the
// language server) stands on.
// 28 — a child you can hold: four slots at the end of the table.
// (see below)
// 29 — `key_read` takes a timeout: under zero blocks as it always
// did; zero or more waits at most that long and answers "idle" when
// nothing arrived, so a program can pump held work between keys.
// `process_spawn` answers a handle whose reads are the child's output
// and whose writes are its input; `process_ready` is the no-block
// poll; `process_wait` the exit status; `process_finish_input` the
// half-close that means end of input.  Closing the handle kills a
// child still running — releasing the last reference cannot leak a
// process.
// 30 — the filesystem completes (docs/FILESYSTEM.md): four slots at
// the end of the table.  `path_size` and `path_modified` are the two
// stat facts a build tool stands on; `dir_remove` takes one empty
// directory; `tree_remove` takes whatever is at a path, everything
// under it included, and is the one path service that does **not**
// follow links — a symlink is removed as a link, never as what it
// points at, because a recursive delete that followed links would
// walk out of the tree it was asked to remove.

/// The symbol a compiled Luce artifact exports for a loader to call.
/// What the thing being called *is* — the machine, the ABI version, the
/// program it holds — is the artifact's tag (`codegen/artifact.zig`).
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
///
/// A callback must return exactly `exhausted`, `no`, or `yes`.  The C ABI
/// cannot prevent a function from returning another integer, but generated
/// code treats such a value as a malformed host and traps `host_unavailable`
/// before it reads any output parameter.
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
///
/// The number is sized for programs that recurse per nesting level of
/// their *input* — parsers, lowerers, tree-walkers — which are
/// well-formed at depths a hand-written loop never reaches.  It is a
/// promise only together with `stack_reserve_bytes`: every stack that
/// hosts Luce frames reserves that much, so the budget trips before
/// the native guard page does.
pub const default_call_depth: i64 = 32768;

/// The native stack under `default_call_depth` frames.  64 MiB gives
/// the budget an average of 2 KiB per frame, which generated code
/// stays well under.  Reserved wherever Luce frames run: macOS
/// executables at link time (`apps/native.zig`), the products by
/// their build, and Linux program entries and every worker on a
/// thread spawned with this size (`apps/host.zig`) — Linux ignores
/// link-time stack requests, so the thread is the reservation.
pub const stack_reserve_bytes: usize = 64 << 20;

/// The run ended after opening a runtime, leaving `leaked` objects alive
/// after ordinary ARC cleanup. A nonzero census can expose a surviving strong
/// cycle or a compiler/runtime lifetime bug, including on a trap or uncaught
/// error. An exhausted run has no census and does not call this slot.
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
    input: [*]const u8,
    input_length: i64,
    text: *[*]const u8,
    length: *i64,
) callconv(.c) Answer;

/// One of the process's own byte streams as a handle: 0 standard
/// input, 1 standard output, 2 standard error.  The handle rides the
/// ordinary `handle_read`/`handle_write`/`handle_flush` slots; closing
/// it is a safe no-op, because the descriptor belongs to the process,
/// not the program.
pub const StandardStreamFn = *const fn (
    context: ?*anyopaque,
    which: i64,
    handle: *i64,
) callconv(.c) Answer;

/// Spawn one child of the host shell with its three streams piped;
/// the handle rides `handle_read` (child stdout+stderr) and
/// `handle_write` (child stdin), and closing it kills a child still
/// running.  `process_finish_input` half-closes stdin — the child's
/// end of input; `process_ready` answers whether a read would land
/// without blocking; `process_wait` blocks for the exit status.
pub const ProcessSpawnFn = *const fn (
    context: ?*anyopaque,
    command: [*]const u8,
    command_length: i64,
    handle: *i64,
) callconv(.c) Answer;

pub const ProcessAskFn = *const fn (
    context: ?*anyopaque,
    handle: i64,
    answer: *i64,
) callconv(.c) Answer;

pub const ProcessPlainFn = *const fn (
    context: ?*anyopaque,
    handle: i64,
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
    text: *[*c]const u8,
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
/// `timeout_ms` under zero blocks until input or end of input; zero
/// or more waits at most that long and answers the name "idle" when
/// nothing arrived — input still alive, nothing to route — which is
/// how a program pumps other work between keys.
pub const KeyReadFn = *const fn (
    context: ?*anyopaque,
    timeout_ms: i64,
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

/// What is at `path` — the one question this boundary was missing
/// (docs/FILESYSTEM.md D11, D16).
///
/// `yes` fills `kind` with one of four numbers:
///
///   * **0 — nothing is there.**  Absence, not refusal.  A host that
///     looked and found no entry says `yes` with 0, because "there is
///     nothing at this name" is an *answer*, and the program meets it
///     as `none` rather than as an error.
///   * **1 — an ordinary file**, the thing a read or a write means.
///   * **2 — a directory**, the thing a listing means.
///   * **3 — something else**: a socket, a device, a fifo, a name a
///     filesystem will describe no further.  One code rather than a
///     taxonomy, because a program that must tell a block device from
///     a door is writing an operating system rather than using one.
///
/// `no` is the world **refusing to say** — a parent directory that
/// will not be searched, a device that failed — which the program
/// meets as `io_failed`.  This is the distinction `file_exists` could
/// not draw: it answered `false` for a file that certainly exists
/// under a directory nobody may open, and the bool had no room to say
/// so.
///
/// **Links are followed** (`stat`, not `lstat`).  The kind is the kind
/// of the thing the path *names*, which is what every other
/// path-addressed service here already means, so a `kind` that
/// answered otherwise would describe a different file from the one the
/// next call touches.  A dangling link is therefore 0: nothing is
/// there to read, which is exactly what the program will find.
pub const PathKindFn = *const fn (
    context: ?*anyopaque,
    path: [*]const u8,
    path_length: i64,
    kind: *i64,
) callconv(.c) Answer;

/// How many bytes the ordinary file at `path` holds — `path_size`.
/// Links are followed, like every other path-addressed service except
/// `tree_remove`.  `yes` fills `answer`; `no` is everything that has
/// no honest byte count — nothing there, a directory, a device, a
/// world that would not say — which the program meets as `io_failed`.
/// A directory's `st_size` is a filesystem implementation detail, not
/// a fact a program can use, so it is refused rather than reported.
///
/// For `path_modified` the answer is milliseconds since the Unix
/// epoch, on `epoch_ms`'s terms — **not monotonic**, the operator owns
/// the clock — and a directory does have one, so only absence and
/// refusal are `no` there.
pub const PathFactFn = *const fn (
    context: ?*anyopaque,
    path: [*]const u8,
    path_length: i64,
    answer: *i64,
) callconv(.c) Answer;

/// Remove the **empty** directory at `path`.  `no` on anything that
/// left it there: not empty, not a directory, never there, refused —
/// the host cannot tell those apart and neither can `Answer`
/// (docs/FAILURE.md).  This is the precise tool; the sweeping one is
/// `tree_remove`.
pub const DirRemoveFn = *const fn (
    context: ?*anyopaque,
    path: [*]const u8,
    path_length: i64,
) callconv(.c) Answer;

/// Remove whatever is at `path` — a file, or a directory and
/// everything under it.  Two rules, each the caller's whole reason for
/// calling:
///
///   * **Nothing there is `yes`.**  The call means "there is nothing
///     at this path when I return" — `dir_create`'s idempotence rule,
///     mirrored — so the caller never writes the existence check that
///     is a race.
///   * **Links are NOT followed.**  A symlink is removed as a link and
///     what it points at is untouched, because a recursive delete that
///     followed links would walk out of the tree it was asked to
///     remove.  This is the one path-addressed service on the table
///     that says `lstat`, and it says so out loud.
pub const TreeRemoveFn = *const fn (
    context: ?*anyopaque,
    path: [*]const u8,
    path_length: i64,
) callconv(.c) Answer;

// ---------------------------------------------------------------------------
// The backend-neutral window/GPU channel (version 19)
// ---------------------------------------------------------------------------

/// The host's backend identifier: 0 Metal, 1 Vulkan, 2 headless.  The
/// standard library validates the closed range before exposing its enum.
pub const GpuBackendFn = *const fn (
    context: ?*anyopaque,
    backend: *i64,
) callconv(.c) Answer;

pub const UiWindowOpenFn = *const fn (
    context: ?*anyopaque,
    title: [*]const u8,
    title_length: i64,
    width: i64,
    height: i64,
    handle: *i64,
) callconv(.c) Answer;

pub const UiWindowSurfaceFn = *const fn (
    context: ?*anyopaque,
    window: i64,
    surface: *i64,
) callconv(.c) Answer;

pub const GpuSurfaceSizeFn = *const fn (
    context: ?*anyopaque,
    surface: i64,
    axis: i64,
    size: *i64,
) callconv(.c) Answer;

pub const GpuSurfaceClearFn = *const fn (
    context: ?*anyopaque,
    surface: i64,
    red: i64,
    green: i64,
    blue: i64,
    alpha: i64,
) callconv(.c) Answer;

pub const GpuSurfaceFillRectFn = *const fn (
    context: ?*anyopaque,
    surface: i64,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    red: i64,
    green: i64,
    blue: i64,
    alpha: i64,
) callconv(.c) Answer;

pub const GpuSurfacePresentFn = *const fn (
    context: ?*anyopaque,
    surface: i64,
) callconv(.c) Answer;

/// Close a native window or surface.  It runs from scope teardown, so its
/// answer is intentionally ignored just like file-handle close.
pub const GpuCloseFn = *const fn (
    context: ?*anyopaque,
    handle: i64,
    kind: i64,
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

// ---------------------------------------------------------------------------
// The transport channel (version 25, docs/NETWORK.md)
// ---------------------------------------------------------------------------
//
// Installed into the runtime once like the handle five, and unlike
// every other slot in this table these MAY BE ENTERED CONCURRENTLY
// and MAY BLOCK: an `accept` waits for a peer, and holding the
// process-wide Effects guard across that wait would freeze every
// other worker's host effects.  The host keeps its handle registry
// behind its own short-held mutex and performs the blocking system
// call outside every lock.  A socket the runtime accepts or connects
// is addressed by the same opaque `i64` a file handle is, and its
// bytes travel `handle_read`/`handle_write`/`handle_flush` unchanged.

/// Resolve `host` and open a TCP connection to it on `port`.  Name
/// resolution is the host's: no address vocabulary crosses here.
pub const SocketConnectFn = *const fn (
    context: ?*anyopaque,
    host: [*]const u8,
    host_length: i64,
    port: i64,
    handle: *i64,
) callconv(.c) Answer;

/// Open a listener on `port`, on every interface.  Port 0 asks for an
/// ephemeral port; `socket_port` answers which one landed.
pub const SocketListenFn = *const fn (
    context: ?*anyopaque,
    port: i64,
    handle: *i64,
) callconv(.c) Answer;

/// Wait for one connection on a listener.  Callable concurrently on
/// one listener from several workers — the pre-fork accept shape.
pub const SocketAcceptFn = *const fn (
    context: ?*anyopaque,
    listener: i64,
    handle: *i64,
) callconv(.c) Answer;

/// The port a listener actually holds.
pub const SocketPortFn = *const fn (
    context: ?*anyopaque,
    listener: i64,
    port: *i64,
) callconv(.c) Answer;

/// Close a socket or listener.  Called from the ownership walk, which
/// has nobody to report to; the answer is read by nothing.
pub const SocketCloseFn = *const fn (
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
    /// Optional — the leak census, reported once at the end of every
    /// run that opened a runtime, including a trap or uncaught error.
    /// Exhaustion has no census and does not call this slot.
    finished: ?FinishedFn = null,
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
    raised: RaisedFn,
    /// Optional services fail closed when absent.
    read_line: ?ReadLineFn = null,
    print_error: ?PrintFn = null,
    clock_ms: ?ClockFn = null,
    sleep_ms: ?SleepFn = null,
    env: ?EnvFn = null,
    file_delete: ?FileDeleteFn = null,
    file_rename: ?FileRenameFn = null,
    dir_list: ?DirListFn = null,
    /// The program's chosen exit status.
    exited: ?ExitedFn = null,
    /// The machine's own facts, behind `std.os`.
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
    /// Version 17: what is at a path (docs/FILESYSTEM.md).  Appended,
    /// so every earlier field keeps its address — including
    /// `file_exists`, which this retires from use without moving.
    path_kind: ?PathKindFn = null,
    /// Version 19: the backend-neutral window/GPU channel.  Native handles
    /// remain opaque to Luce and are closed by the runtime's ownership walk.
    /// Hosts may leave every slot null; a call then fails closed with
    /// `host_unavailable` until a Metal, Vulkan, or headless backend is
    /// installed.
    gpu_backend: ?GpuBackendFn = null,
    ui_window_open: ?UiWindowOpenFn = null,
    ui_window_surface: ?UiWindowSurfaceFn = null,
    gpu_surface_size: ?GpuSurfaceSizeFn = null,
    gpu_surface_clear: ?GpuSurfaceClearFn = null,
    gpu_surface_fill_rect: ?GpuSurfaceFillRectFn = null,
    gpu_surface_present: ?GpuSurfacePresentFn = null,
    gpu_close: ?GpuCloseFn = null,
    /// Version 25: the transport channel (docs/NETWORK.md).  Installed
    /// into the runtime like the handle five, and different from every
    /// slot above in one deliberate way: **these callbacks block for a
    /// peer, run outside the Effects guard, and must be thread-safe** —
    /// the host keeps its registry behind its own short-held mutex and
    /// performs the blocking system call outside every lock.  Connected
    /// sockets then travel `handle_read`/`handle_write`/`handle_flush`
    /// unchanged, which is what those slots' names always promised.
    socket_connect: ?SocketConnectFn = null,
    socket_listen: ?SocketListenFn = null,
    socket_accept: ?SocketAcceptFn = null,
    socket_port: ?SocketPortFn = null,
    socket_close: ?SocketCloseFn = null,
    /// The system clipboard, receiving what the program copied.  A
    /// terminal host emits OSC 52; a host with no clipboard leaves
    /// the slot null and the program traps `host_unavailable`.
    term_copy: ?TermWriteFn = null,
    standard_stream: ?StandardStreamFn = null,
    process_spawn: ?ProcessSpawnFn = null,
    process_ready: ?ProcessAskFn = null,
    process_wait: ?ProcessAskFn = null,
    process_finish_input: ?ProcessPlainFn = null,
    /// Version 30: the filesystem completes (docs/FILESYSTEM.md).  Two
    /// stat facts and two removals, appended together in one bump for
    /// the reason the handle five were: a version is a rebuild of every
    /// artifact there is.  All optional and fail-closed.
    path_size: ?PathFactFn = null,
    path_modified: ?PathFactFn = null,
    dir_remove: ?DirRemoveFn = null,
    tree_remove: ?TreeRemoveFn = null,
};

/// The index of each `Host` field, as the generated code addresses it.
/// `getelementptr` walks a struct of `count` pointers with these
/// indices, so the order here is the memory layout above.
pub const Slot = enum(u32) {
    context = 0,
    print = 1,
    trap = 2,
    finished = 3,
    arg_count = 4,
    arg = 5,
    term_rows = 6,
    term_cols = 7,
    term_clear = 8,
    term_move = 9,
    term_style = 10,
    term_write = 11,
    term_flush = 12,
    key_read = 13,
    call_depth = 14,
    raised = 15,
    read_line = 16,
    print_error = 17,
    clock_ms = 18,
    sleep_ms = 19,
    env = 20,
    file_delete = 21,
    file_rename = 22,
    dir_list = 23,
    exited = 24,
    os_total_memory = 25,
    os_available_memory = 26,
    os_cpu_count = 27,
    handle_open = 28,
    handle_read = 29,
    handle_write = 30,
    handle_flush = 31,
    handle_close = 32,
    worker_spawn = 33,
    worker_join = 34,
    shell_run = 35,
    term_event_data = 36,
    dir_create = 37,
    epoch_ms = 38,
    path_kind = 39,
    gpu_backend = 40,
    ui_window_open = 41,
    ui_window_surface = 42,
    gpu_surface_size = 43,
    gpu_surface_clear = 44,
    gpu_surface_fill_rect = 45,
    gpu_surface_present = 46,
    gpu_close = 47,
    socket_connect = 48,
    socket_listen = 49,
    socket_accept = 50,
    socket_port = 51,
    socket_close = 52,
    term_copy = 53,
    standard_stream = 54,
    process_spawn = 55,
    process_ready = 56,
    process_wait = 57,
    process_finish_input = 58,
    path_size = 59,
    path_modified = 60,
    dir_remove = 61,
    tree_remove = 62,

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
