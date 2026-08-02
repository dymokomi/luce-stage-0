# Debug and release — the two build modes

Luce has exactly two build modes, and they differ in one thing only:
**what a trap can tell you**.

```sh
luce build dice.luc              # debug (the default)
luce build dice.luc --release    # stripped
```

Both build paths mean the same thing by it.  The LLVM path (`luce
build --backend=llvm`) emits the origins as constant data beside the
code rather than as LLVM debug metadata, and `--release` leaves them
out; everything below is true of a compiled artifact as well as of the
`.lc` the interpreter runs.

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

- The interpreter's dispatch loop never reads origins.  Not a load,
  not a branch — the hot path is byte-for-byte identical whether the
  tables exist or not.  Neither does generated code: its origins are
  constant data nothing on the execution path addresses.
- On a trap, the frame stack is still intact (frames only pop on
  return), so the interpreter walks it once, resolves each frame's
  current instruction through its function's origins table, and
  attaches the trace to the trap.  All cost sits on the far side of
  "the program already failed."
- Compiled code has no such stack to walk — its frames are native
  frames, gone by the time anyone could read them — so it builds the
  trace *as it unwinds*: each frame records which function and which
  instruction it was at on the way out, and `luce_main` reports the
  finished trace with the trap.  Same bargain, same far side of the
  failure (`src/luce/runtime/trace.zig`).
- Deep recursion is capped: a trace keeps the innermost 64 frames
  and counts the rest (`... 262132 more frames`), so a
  `call_depth_exceeded` report is readable and cheap.  Both engines
  cap at the same number, so the same trap reports the same frames.

So the honest statement is: **debug and release run at identical
speed**; release buys a smaller `.lc` (roughly a third off, more
when functions are long) and gives up trap locations.  Ship
`--release` when module size matters or source lines would mean
nothing to the recipient; ship debug everywhere else.  When a
release module misbehaves, recompile from source and reproduce —
the deterministic interpreter makes that reliable.

## What's in the tables

Per function: the source file name (`dice.luc`, `strings.luc` — the
std modules resolve like any other, so a trap inside
`strings.format_float` points into `strings.luc`), and one
`line:column` pair per instruction.  Granularity is the statement,
the way Python tracebacks work: every instruction a statement lowers
to reports the statement's own position.  The tables live in the
`.lc` beside the code they describe (`format_version` 10) and, on the
LLVM path, in a private constant array beside the machine code; the
decoder rejects a table whose length disagrees with its function's
instruction count, and the verifier enforces the same invariant on
every program, decoded or freshly compiled.

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
- `src/luce/interpreter/machine.zig` — `traceback()`: where the
  interpreter reads origins, after a trap, never during execution.
- `src/luce/backend.zig` — `Trap.trace` (`TraceFrame` = function,
  source, line, column) and `Trap.dropped`.
- `src/luce/runtime/trace.zig` — the same trace for compiled code:
  the C-layout tables, the unwind recorder, and the one report that
  carries the whole trap.
- `src/luce/08_llvm/lower.zig` — emits those tables as constant data
  and calls `luce_rt_unwound` on every unwinding edge.
- `src/apps/loom/runner.zig` — renders the trace, capped at 12
  printed frames.
- `src/apps/luce/main.zig` — the `--release` flag, on both backends.
