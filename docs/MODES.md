# Debug and release — the two build modes

Luce has exactly two build modes, and they differ in one thing only:
**what a trap can tell you**.

```sh
luce build dice.luc              # debug (the default)
luce build dice.luc --release    # stripped
```

Every shape means the same thing by it.  The origins travel as
constant data beside the code rather than as LLVM debug metadata, and
`--release` leaves them out; everything below is true of the `.lc`
loom runs, of a standalone executable, and of the serialized module
the two are built from.  An artifact's tag records which of the two
modes it is, so a loader can say so without running it
(`artifact.Artifact.debug`).

A debug module carries *origins* — for every IR instruction, the
line and column of the statement it came from, plus the source file
name per function.  When a program traps, loom prints the location
and the whole call stack:

```
loom: trap: division by zero [divide_by_zero]
    at divide (crash.luc:5:5)
    at ratio (crash.luc:8:5)
    at main (crash.luc:12:5)
```

A release module has the tables stripped.  Traps still carry their
stable code, message, and function names (names are structure, not
debug info), but no lines:

```
loom: trap: division by zero [divide_by_zero]
    at divide
    at ratio
    at main
```

`loom luce FILE.luc` (compile-and-run) is always a debug build —
when the source is sitting right there, there is no reason not to
know the line.  Bundled programs install as debug builds too.

## Semantics never change between modes

This is the deliberate departure from Zig, and the core decision.
Zig's four modes (`Debug`, `ReleaseSafe`, `ReleaseFast`,
`ReleaseSmall`) trade safety checks for speed: `ReleaseFast` turns
integer overflow into undefined behavior.  Luce refuses the trade.
Checked arithmetic, bounds checks, UTF-8 boundary checks, ownership
traps — those are the *language*, not a mode.  A program traps on
the same instruction with the same stable code in both modes, so
there is no "works in debug, corrupts in release" class of bug, and
release needs no separate testing story.  In Zig's terms, Luce is
always `ReleaseSafe`; `--release` is closer to `-fstrip`.

## Release is hyper fast because debug was already free

The lesson taken from Zig is *where* the cost of debug info lives.
A Zig binary's panic handler parses its own DWARF lazily, at panic
time (`std.debug.SelfInfo`); until a crash actually happens, the
line tables are inert bytes.  Luce works the same way:

- Generated code never reads origins.  Not a load, not a branch — its
  origins are constant data nothing on the execution path addresses,
  so the hot path is byte-for-byte identical whether the tables exist
  or not.
- It has no frame stack to walk either — its frames are native frames,
  gone by the time anyone could read them — so it builds the trace *as
  it unwinds*: each frame records which function and which instruction
  it was at on the way out, and `luce_main` reports the finished trace
  with the trap.  All cost sits on the far side of "the program
  already failed" (`src/luce/runtime/trace.zig`).
- The oracle strikes the same bargain by the opposite route.  Its
  dispatch loop never reads origins either, and on a trap its frame
  stack is still intact (frames only pop on return), so it walks it
  once and resolves each frame's current instruction through its
  function's origins table.  Two mechanisms, one report — which is
  exactly what `specs/agree.zig` compares, frame for frame.
- Deep recursion is capped: a trace keeps the innermost 64 frames
  and counts the rest (`... 262132 more frames`), so a
  `call_depth_exceeded` report is readable and cheap.  Both arms
  cap at the same number, so the same trap reports the same frames.

So the honest statement is: **debug and release run at identical
speed**; release gives up trap locations and buys very little back.
It takes roughly a third off the serialized module, and an artifact is
mostly the runtime library it carries, so on the `.lc` itself it is
**about 2%** (`editor.lc`, the largest bundled program: 805 KB → 789 KB)
and nothing measurable on a small program.  Ship `--release` when source lines would mean nothing
to the recipient; ship debug everywhere else.  When a release artifact
misbehaves, recompile from source and reproduce — the language is
deterministic, so that is reliable.

## What's in the tables

Per function: the source file name (`dice.luc`, `strings.luc` — the
std modules resolve like any other, so a trap inside
`strings.format_float` points into `strings.luc`), and one
`line:column` pair per instruction.  Granularity is the statement,
the way Python tracebacks work: every instruction a statement lowers
to reports the statement's own position.  The tables live in the
serialized module beside the code they describe and, in the artifact,
in a private constant array beside the machine
code; the
decoder rejects a table whose length disagrees with its function's
instruction count, and the verifier enforces the same invariant on
every program, decoded or freshly compiled.

An uncaught **error** reads the same tables and follows the same
rule, for one position instead of a stack: a debug build says `raised
in Scan.number (calc.luc:35:13)` and a `--release` build says `raised
in Scan.number`. An error records that position once, where it was raised, and
never assembles a trace — which is what keeps the *success* path of a
`try` free of anything to save and restore (docs/FAILURE.md).

Compile-time diagnostics are unchanged by all of this: they carry
byte spans and stable codes in both modes, and render as
`file:line:column` always — modes are about *runtime* reporting.

## The machinery, file by file

- `src/luce/04_semantics/` — the builder stamps every emitted
  instruction with the current statement's offset; one post-pass per
  function converts offsets to `line:column` through a per-module
  line-start table (built once, binary-searched).
- `src/luce/06_mir/` — `Origin`, `Function.origins`/`source`, the
  verifier's all-or-nothing length check, and `strip()`.
- `src/luce/06_mir/module.zig` — origins ride in the function record;
  `--release` writes empty tables.
- `src/luce/runtime/trace.zig` — the trace compiled code carries: the
  C-layout tables, the unwind recorder, and the one report that
  carries the whole trap.
- `src/luce/08_llvm/lower.zig` — emits those tables as constant data
  and calls `luce_rt_unwound` on every unwinding edge.
- `src/apps/report.zig` — renders the trace, capped at 12 printed
  frames (`max_printed_frames`), for loom and for a standalone binary
  alike: one rendering, so a program's behaviour does not depend on
  who started it.
- `src/apps/luce/main.zig` — the `--release` flag: it strips the
  module, and everything downstream follows from that.
- `src/luce/interpreter/machine.zig` — `traceback()`: where the oracle
  reads origins, after a trap, never during execution; and
  `src/luce/interpreter.zig` — `Trap.trace` (`TraceFrame` = function,
  source, line, column) and `Trap.dropped`, the shape `specs/agree.zig`
  compares against the compiled report.
