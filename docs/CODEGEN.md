# Code generation — the LLVM path

Luce has one code generator.  It lowers the typed Luce IR to LLVM IR,
hands that to libLLVM, and gets back machine code.  This file is both
the decision record for that seam and the description of what is
there.

The path is **the only one**: `luce build` writes a loadable artifact
and calls it `.lc`, `--emit=exe` writes a standalone binary, and
`loom run FILE.lc` opens and calls machine code.  The interpreter is
no longer an engine — it ships in nothing and survives as the
differential oracle in the test suite (docs/ENGINE.md).  What follows
says exactly how far this path reaches and how it reaches a person.

Where this file compares the compiled answer against "the
interpreter", it means the oracle: the second implementation the specs
run every program on and compare against, not something a user can
select.  There is nothing to select.

## The pipeline

```text
FILE.luc → 02_lex → 03_parse → 04_semantics → typed MIR → 07_optimize
                                             ↓
                            std.zig.llvm.Builder  (08_llvm/lower.zig)
                                             ↓
                                        LLVM bitcode
                                             ↓
                     libLLVM: parse, default<O3>, emit  (08_llvm/emit.zig)
                                             ↓
                                  FILE.o  (relocatable object)
                                             ↓
                            cc  (src/apps/native.zig)
                                    ↓                ↓
                            FILE.lc             FILE (executable)
```

```sh
luce build FILE.luc                 # FILE.lc   — loom loads and calls it
luce build FILE.luc --emit=object   # FILE.o    — you link it
luce build FILE.luc --emit=exe      # FILE      — a shell runs it
```

The object is built for the host triple, is position-independent,
exports `luce_main` and its artifact tag, and declares no undefined
symbols beyond `libluce_rt`.  That last claim is proved by the link
itself, which is why linking is part of the shipped path rather than
only of a test.

## Getting it to a person

Three questions had to be answered, and the answers are all in
`src/apps/native.zig` and `src/apps/start.zig`.

**Who links, and with what.**  `cc`, at build time.  A link is a
*build-time* act — every `luce build` is one, and so is the compile
loom does the first time it meets a source file with no current
artifact — and nothing external is invoked on the **run** path at all.
Running an artifact that already
exists is one `dlopen`, one symbol lookup, one call.  Using LLD
in-process would be nicer, and was checked: LLD is not part of what
`llvm-config` describes (Homebrew ships it as a separate formula, and
`--libs` never names it), so reaching it means discovering a second
toolchain or vendoring one.  `cc` is present wherever a C toolchain
is, and knows its own platform's SDK paths, crt objects and system
libraries.  `LUCE_CC` names another driver.

**What an executable's `main` is.**  `libluce_start.a`, built from
`src/apps/start.zig` and installed beside `libluce_rt.a`: it builds a
`LuceHost`, calls `luce_main`, and turns the status into an exit code
and a trap report.  **Its services are loom's, not a second set** —
the same `src/apps/host.zig`, so a standalone binary offers the same
console, the same cwd-relative files, the same 256-color terminal and
the same key names as `loom run`.  So is its arithmetic on the way
out: the exit statuses and the two failure renderings live in that one
file, and both runners answer from it.  **`0` finished, `1` trapped,
`3` ended on an uncaught error, `70` ran out of memory, `71` could not
be run or could not deliver its output** — a trap and an error being
two different sentences about a program (docs/FAILURE.md), which is
why a script reading `$?` can tell them apart without parsing stderr.  Terminal services in a non-loom
binary were the open question, and null slots (fail closed, trap
`host_unavailable`) would have been defensible — but they would make
"the compiled program behaves identically" true of one runner and not
the other, and two of the nine bundled programs draw on a screen.  A
program's behaviour must not depend on who started it.

For that to be a small library rather than a copy of the compiler,
`abi.zig` takes the trap channel's C shapes from `runtime/trace.zig`
rather than from the `runtime.zig` barrel, which force-analyzes the
whole `luce_rt_*` surface.  `libluce_start.a` therefore has exactly
two undefined Luce symbols — `luce_main` and `luce_artifact` — and no
second copy of the runtime to collide with the real one at link time.

**How an artifact says what it is.**  It exports `luce_artifact`, a
constant `abi.Artifact`: a magic, the tag's own layout version, the
host ABI version, the machine, a hash of the serialized module it was
built from, what generated the code, and whether it kept its origins.
A loader reads that *before* it calls anything, and refuses by name —
wrong machine, wrong ABI, wrong code generator, stale program —
because a native artifact is not portable and a file name cannot be
trusted to say so.  Without the tag, a `.lc` copied between machines
is a file that loads cleanly and crashes with no explanation.

The machine is `abi.machine` — `aarch64-macos-none`, architecture,
system and C ABI from `builtin` — and **not the LLVM triple**, which
is what it used to be.  The triple is a codegen input: LLVM invents
it, LLVM parses it, and asking for it means having libLLVM in the
process.  A loader is asking a different question — may this library
be opened and called here? — and those three fields answer it exactly.
Making the tag readable without a code generator is what lets loom
carry no LLVM at all (below).  CPU features are absent because nothing
generates for a named CPU; the day that changes, the string grows and
`abi.version` moves with it.

### Where a compiled artifact lives, and when it is rebuilt

A `.lc` **is** the artifact: `luce build NAME.luc` writes one and
`loom run NAME.lc` opens it.  What is cached is the compile that loom
does on a person's behalf — `loom luce NAME.luc` puts the result
beside the source, as `NAME.lc`, exactly the file `luce build` would
have written, so a second run finds a warm one.  It is deletable with
the program and visible in a listing, which a hidden cache is not.
When there is nowhere to write beside the program — a read-only
directory, or a program with no path at all, like the editor embedded
in loom — the artifact goes to the session's own `TMPDIR` under its
hash.  (`TMPDIR` rather than `/tmp`: the file gets `dlopen`ed, and a
world-writable directory is not where that should be decided.)

**The key is content, never a timestamp.**  The tag carries
`abi.sourceHash` of the serialized module, so a rebuild that produced
identical bytes hits, a program whose bytes changed misses, and a file
restored from a backup with an old mtime does not quietly win.  That
is PEP 552's answer rather than PEP 3147's.

**And the content is the compiler's as well as the program's.**  A
`.lc` holds machine code, and which machine code depends on two
independent things: the program, and whatever turned it into
instructions.  `source_hash` answers the first.  `abi.generator`
answers the second, and the tag carries both, so upgrading `luce`
rebuilds every artifact instead of leaving the previous compiler's
output running under a program whose module re-encodes to the same
bytes.  A loader tells the two apart — "the program it was built from
has changed" and "it was built by a different code generator" are
different sentences, because they are different facts and only one of
them is something a person did to the program.

**The generator identity is computed, not declared.**  A hand-bumped
number is the shape `abi.version` and the serialized module's
`format_version` have,
and it is the wrong shape here: an ABI changes a few times a year, a
code generator changes every day, and forgetting to bump is exactly
how an artifact goes stale unnoticed.  So `build.zig` hashes what
actually decides the answer and hands the one number to both binaries
through `addOptions` — `luce` stamps it, `loom` compares its own
compiled-in constant, and a `luce` and a `loom` from different builds
correctly disagree.  It costs a warm run nothing: no file is read, no
binary is hashed, and loom still looks for the compiler only on a
miss.  Hashing the `luce` binary itself would have covered more, and
was rejected for that — 55 MB rehashed on every warm run against a
1.9 ms startup, to answer a question a build-time constant answers for
free.

What the number covers, all by content and never a clock:

- **The lowering and the emitter** — every `.zig` under
  `src/luce/08_llvm/`, plus the barrel.
- **`libluce_rt`** — every `.zig` under `src/luce/runtime/`, plus the
  barrel, since `cc` links it into the artifact.
- **How those are compiled** — the Zig version, the optimize mode, the
  target triple, and the CPU model and feature set, because the same
  runtime source built three ways is three different libraries.
- **libLLVM** — `llvm-config --version` and `--host-target`, the
  second because `emit.hostTriple` will ask that same library what to
  generate for.

Whole directories rather than a list of the interesting files in them:
a list is a thing to forget, and forgetting is the failure this exists
to end.  Counting a test file costs one rebuild that was not needed;
missing a file that matters costs a wrong answer.

What it misses, and knowingly: **two different builds of the same
LLVM version** — a distribution patch, different CMake flags — because
the library is hundreds of megabytes and this runs on every configure,
and `./vendor-llvm.sh` pins a single revision anyway.  And **the `cc`
that links the artifact**, which combines objects rather than
generating them.  Both are named here rather than assumed away.

Because the tag is honest, nothing has to sweep artifacts before
measuring one: `bench/run.sh` and `bench/compare.sh` leave the `.lc`
files where they are and let the loader refuse the stale ones, which
also keeps them a live test that it does.

### What running a program costs

`loom run FILE.lc` is one `dlopen`, one symbol lookup, one call.
There is no engine to choose and nothing to fall back to: the file is
machine code, so running it needs no compiler, no C toolchain, no
LLVM, and nowhere to write.  A **source** file needs all four, exactly
as a `.c` does, and when one is missing loom says which — "the `luce`
compiler is not beside /usr/local/bin and not on PATH" — rather than
running the program some other way.

Measured on the bundled programs and the benchmark set (M4 Max, best
of several):

| program | warm | cold (compile + link + first load) |
|---------|------|------------------------------------|
| hello   | 4.0 ms | 137 ms |
| editor  | 4.0 ms | 291 ms |
| loops   | 84 ms  | 233 ms |
| matmul  | 12 ms  | 159 ms |
| strings | 52 ms  | 230 ms |

Warm startup is process start and `dlopen`, and nothing else.  A cold
run — a source file loom has not compiled before — pays one `luce`
process, LLVM at `-O3`, one link, and the first `dlopen` of a binary
the OS has never seen, which on macOS is the largest single term of
the four (89 ms of `sort.luc`'s 155; docs/ENGINE.md Hat 3).  It is
paid once per change to the program.

### loom does not carry a code generator

**`luce` is the compiler and links libLLVM; `loom` is the environment
and does not.**  When loom meets a program with no current artifact it
runs the `luce` binary over the serialized module it is already
holding.

The reason is dyld.  Homebrew's `libLLVM.dylib` is 164 MB, and a
process that names it maps and binds all of it before `main` — 5.7 ms
on this host, measured against an otherwise identical binary, with
zero LLVM functions ever called.  loom's whole job is starting
programs, so it paid that on every single invocation: warm runs, cold
runs, and `loom` with no arguments alike.  Against a C do-nothing
binary at 2.4 ms, loom's floor was 8.8 ms; it is now 3.1 ms, and
`bench/matmul` went from 1.7x of its C twin to 1.08x with no change to
a single generated instruction.

What makes the split possible is that almost nothing needs libLLVM.
`lower.zig` builds LLVM IR with `std.zig.llvm.Builder`, which is pure
Zig and links nothing; the artifact tag names its machine with
`abi.machine` rather than an LLVM triple, so a loader can check it
with no library at all.  Exactly one file calls the C API —
`08_llvm/emit.zig` — and it is its own build module (`emit`) that only
the `luce` executable imports.  `otool -L build/loom` is the check.

- loom finds the compiler **beside its own executable first, then on
  `PATH`** (`native.findCompiler`).  Beside first is what a toolchain
  does and what keeps an install tree self-consistent: a `loom` from
  `build/` builds with the `luce` from `build/`, never with whatever
  an older install left earlier on `PATH`.
- What it hands over is **the module, not the source**: the artifact
  is then keyed to the exact program about to run, rather than to
  whatever a second compile of the same file would have produced.  The
  module reaches the compiler as a `.lcm` — loom writes
  `NAME.lc.<pid>.lcm` beside the artifact it is about to build and
  removes it again.  Re-encoding a decoded module is byte-identical
  (`06_mir/module.zig`), so the hash matches by construction.  `luce
  build`, `luce check` and `luce ir` all accept a `.lcm` for the same
  reason, and that front-end/back-end split is a capability in its own
  right.  Nothing writes one as a deliverable: there is no
  `--emit=module`.
- The compiler inherits loom's environment, so `LUCE_LIB` and
  `LUCE_CC` reach it without loom parsing or forwarding either.
- **A machine that only runs Luce programs needs no LLVM installed.**
  That is the distribution property the split buys, and it is worth
  more than the milliseconds.

`luce` still pays the 5.7 ms, and that is left alone: `luce build`
genuinely uses LLVM, and paying dyld once per compile is not worth a
second binary or turning `emit.zig`'s twenty `extern fn`s into
`dlopen`ed function pointers.  `luce check` and `luce ir` are the two
commands that pay it for nothing (8.4 ms against loom's 2.7 ms); if
check-on-save latency ever matters, the fix is the one loom just got —
another binary — and not lazy binding.

**Two rules govern `lower.zig`**, both inherited from what the deleted
hand-written backends cost:

- No `else` arm.  The switches over `ir.Instruction` and
  `ir.Intrinsic` name every tag, so a new IR instruction is a compile
  error here rather than a silent fallthrough.
- No `unreachable` for "not yet".  Anything without a lowering returns
  `.unsupported` naming the tag, so a gap is a message and never wrong
  code.

**IR construction uses `std.zig.llvm.Builder`** — the pure-Zig builder
in the pinned standard library — and links nothing.  `emit.zig` is the
only file in the tree that touches libLLVM, and it uses the narrowest
tier of the C API: parse a bitcode buffer, make a target machine, run
a textual pass pipeline, write an object.  That is the tier LLVM's own
developer policy describes as stable; IR *construction*, the part that
has broken repeatedly across releases, stays in-tree.  Being one file
is also what makes it one *module*, which is what keeps libLLVM out of
loom.

**Both optimizer knobs say O3**, and the interesting thing is that
they used not to.  The pass pipeline is `default<O3>` for one argued
reason — nontrivial loop unswitching, which O2 disables and which is
what lifts a bounds check out of a loop so the vectorizer can have it
(`Options.passes`) — while the target machine was left at
`LLVMCodeGenOptLevel` 2, never argued and simply unnoticed, so
instruction selection and register allocation worked less hard than
the pipeline that fed them.  Raising it was A/B'd on every `bench/`
row (`bench/compare.sh`, twice): every row inside the round-to-round
spread, with the signs flipping between runs.  It is kept anyway, and
not for the speed — two knobs that both mean "how hard to optimize"
pointing at two numbers is a question a reader has to answer twice,
and the honest answer to "why O2 here" was that nobody had chosen it.

**The stage directory is `08_llvm/`, and the numeric prefix is what
makes that name legal.**  Zig derives symbol names from the source
path, and LLVM claims every symbol beginning `llvm.` as one of its own
intrinsics: a file at `src/luce/llvm/abi.zig` makes the compiler abort
with "llvm intrinsics cannot be defined!".  `08_llvm/abi.zig` yields
`08_llvm.abi.…`, which does not begin `llvm.`, so the check never
fires.  Never drop the prefix from this one.

## The generated module

Each Luce function becomes an `internal` LLVM function whose `i32`
result is the **outcome**:

```llvm
define internal i32 @"luce.3.gcd"(ptr %host, ptr %rt, i64 %depth, i64 %0, i64 %1, ptr %out)
```

`0` returned, `1` trapped, `2` errored.  Anything but `0` means the
program is unwinding and `%out` must not be read.  A trap is fatal and
uncatchable, so it only travels one way and every caller propagates it
unchanged; an **error** may be caught, so a caller that wrote `try` or
`catch` branches on the word instead (see below).  A returned value
goes through `%out`, which is absent when the function returns
nothing.  Every function carries `%host`, `%rt`, and `%depth` as
hidden leading arguments.

That convention beat the zero-cost alternative — a `noreturn` host
callback plus `longjmp` — because it needs no platform unwinding
machinery and works unchanged on wasm32.  It was an `i1` until errors
arrived; widening it cost nothing (a register either way, `internal`
linkage, no stability promise) and bought the whole error channel.

Locals are entry-block `alloca`s that mem2reg promotes.  Every
`alloca`, including scratch slots created deep in the walk, is emitted
in the entry block, so nothing accumulates inside a loop.

## Call depth, and the trace a trap carries

Luce promises that runaway recursion **traps** — a stable code, a
message, a call stack — rather than overflowing the machine's own
stack.  The oracle keeps that promise by counting frames on the
explicit stack it runs on.  Generated code runs on the native stack,
so it counts differently: `%depth` is how many Luce frames are still
allowed *including this one*, a callee is handed one less, and a call
that would take it to zero traps `call_depth_exceeded` at exactly the
call where the oracle's frame stack would have refused to grow.

That is a register subtract and a compare against a constant, and the
limit is the same whether or not LLVM inlined the callee, because the
arithmetic is in the IR rather than in the stack pointer.  It also
costs nothing measurable: LLVM hoists the check to the top of each
function and folds it into the decrement, so recursive `fib` pays one
`subs` and one branch per *function*, not per call.  A/B against a
build with the check removed measured `-0.75%` to `+0.63%` across
`loops`, `matmul`, `fib(35)`, a mutually recursive Ackermann, and a
hundred-million-call loop — noise in every case.

How deep is too deep is the host's to say, through the ABI's
`call_depth` slot; a null slot means `abi.default_call_depth`, which
is `interpreter.Budget`'s default too, so the oracle and the compiled
artifact refuse the same call.  A host is free to name an enormous
number, but the machine's stack is
still finite: a limit above what it can hold is a limit that never
fires.

**The trace costs nothing at all until a trap happens.**  There is no
LLVM debug metadata on this path and none is wanted.  Every exit on
the unwinding path — an inline trap, the edge after a call that
trapped — first calls `luce_rt_unwound` with the function's index and
the instruction it was at, so the trace assembles itself innermost
first as the program leaves.  The names and the source positions
travel as constant data emitted once per module and handed to
`luce_rt_open`; a `--release` artifact emits the names and drops the
origins, so it still prints `at divide / at ratio / at main` with no
lines, exactly as docs/MODES.md describes.  Nothing on the execution
path reads any of it — not a load, not a branch — which is the same
bargain the interpreter strikes.

Because the trace only exists once unwinding is over, the trap is
reported once, from `luce_main`, with everything in it.

Scalars are generated inline: checked integer arithmetic, comparison,
branches, calls.  So are the container shapes a numeric program spends
its time in — see "Inline access" below.  Everything else below the
instruction level is a call into `libluce_rt`.

## Inline access

An `array` element and the string primitives are **generated, not
called**.  `a[i]`, `grid[r, c]`, `len(a)`, `a.dim(k)`, `s.byte_at(i)`,
`s[a:b]` and `len(s)` all lower to the bounds check and the load they
are, with no boxed subscript and no call.

The box, not the call, is the barrier: a value crosses into
`libluce_rt` through a 24-byte `alloca` that has to be refilled at
every use, and LLVM cannot hoist a store to memory whose address is
passed to a call.  So a loop-invariant box pins the call inside the
loop however precisely the call is described.

This is stage 10's work rather than stage 9's because MIR has no load,
no `getelementptr` and no pointer: the transformation is not
expressible above LLVM IR.  And it is not LLVM's work either, because
the object's kind lives in MIR's type table and nowhere in the emitted
IR — `heap_types` says statically that a handle is an
`array(double, _)`, which collapses the runtime's four-way switch to one
arm before an instruction is emitted.

Three things make it pay, and all three are needed together:

- **The row is walked directly.**  `runtime.layout` (in
  `runtime/heap.zig`) gives the byte offsets of the object table's
  base, a row's `alive` byte, and an array's `dims`, `elements` and
  `count`.  Every one is measured from the Zig types with `@offsetOf`
  and checked against a real `Runtime` by a test beside them, so the
  two cannot drift.  An array's storage is a field of the row rather
  than a payload inside the `data` union for exactly this reason: Zig
  promises a layout for a struct field and none for a tagged union's
  payload.
- **Elements are stored as themselves.**  An `array(double)` is `f64`s,
  an `array(long)` is `i64`s, an `array(bool)` is bytes; only Strings,
  structs and objects keep the 24-byte slot.  `Value` is the
  *boundary* type — how an element crosses into a caller — never the
  storage type.  Reading a double element becomes one `ldr d0`, the
  memory traffic is a third of a boxed array's, and an array of
  untagged doubles is the only kind that can ever reach a SIMD unit or
  a GPU.
- **The resolution leaves the loop** (`08_llvm/loops.zig`).  Resolving
  at every access leaves four loads in front of every element read,
  and LICM cannot lift them: the loop also *stores* an element through
  a pointer loaded out of the row, and nothing in the IR says the two
  do not overlap.  Saying otherwise wants TBAA or `!alias.scope`, and
  `std.zig.llvm.Builder` attaches metadata to branches and to nothing
  else.  So the compiler does it: the row is read once in the
  preheader of the outermost loop that cannot disturb it — nothing
  that attaches an object, frees one, or replaces an array's storage
  (`optimize.effects.viewStable`).

  **The metadata exists now, and the honest number is: it moved
  nothing this suite measures** (task #45, ruled and executed
  2026-08-06).  The Builder is vendored (`08_llvm/builder/`, three
  files, `LUCE:`-marked deviations only) and attaches `!alias.scope`
  and `!noalias` on every row-fact load and every scalar cell access
  — two scopes, rows and elements, that never overlap by
  construction.  An interleaved A/B against the commit before the
  attachment landed reads within noise on every row, matmul and
  arrays included, because the hand-hoisting above had already banked
  the win the scopes describe: a value in a register cannot be
  invalidated by a store, metadata or no metadata.  The scopes are
  kept anyway, and not sentimentally — they cover what the manual
  hoist cannot reach (views die at every call and every block edge;
  the scopes survive both), they are what a future pass that *stops*
  hand-hoisting would stand on, and they cost nothing measured.
  `!range`/`!nonnull` remain unattached until the runtime's
  never-null cases are proven rather than assumed — a wrong
  attachment is a miscompile, not a slowdown.

**The loads move; the checks stay.**  A lifted resolution reads a row
without deciding anything about it — a null handle reads an all-zero
dead row, so the loads are safe unconditionally — and every access
still tests the handle for null and the row for `alive` before it
touches an element.  A trap fires at exactly the instruction that owes
it, with exactly the trace it had before, and a loop that runs zero
times over a freed array still traps nowhere.  What the loop is left
holding is two comparisons against loop-invariant values, which LLVM's
own unswitching lifts, and the bounds check, which it keeps and then
versions the loop around — that is what lets the vectorizer in.

Measured against the C twins on an Apple M4 Max, best of three, both
sides through LLVM, process startup taken off both — `bench/run.sh`'s
`compute` column, which is what a change to code generation moves:

| benchmark | before | after |
|-----------|--------|-------|
| matmul    | 73.9x  | 0.97x |
| arrays    | 12.7x  | 1.06x |
| stats     |  8.5x  | 0.99x |
| strings   |  2.5x  | 1.73x |
| loops     |  1.04x | 1.04x |
| math      |  1.03x | 1.03x |

**Both columns are this change's A/B and neither is a current
figure**, `strings` least of all: copy-on-store and small-string
optimisation both landed afterwards and moved that row twice.  The
snapshot below is the live table.

`map` is deliberately not on the inline path: a hash probe is genuinely
call-worthy.  Neither is `list`, whose buffer moves under `append`, nor
`find_byte`, which is a vectorized `memchr` in the runtime and would be
slower unrolled here.

## The extrema, and why a `min` reduction vectorizes

`min`, `max` and `clamp` on double are generated too, and *which*
intrinsic they are generated as is a decision about meaning before it
is one about speed.

LLVM offers three, and only one of them says anything definite.
`llvm.minnum` leaves `(-0.0, +0.0)` unspecified, so its constant
folder answers the first operand while every target's instruction
answers `-0.0` — one value computed two ways, differing by whether an
optimizer reached it, which is not a semantics at all.  `llvm.minimum`
is specified there but propagates NaN, where Luce answers the operand
that is a number.  `llvm.minimumnum` — IEEE 754-2019 `minimumNumber` —
is both at once: `-0.0` below `+0.0`, and a NaN as an identity rather
than an absorber.  That is what Luce's `min` means and what the
interpreter's `@min` does, so that is what is emitted, and `clamp` is
the two composed in the interpreter's order.  It is declared by name
rather than through `builder.Intrinsic`, whose table in the pinned
standard library predates the 2019 pair; LLVM recognizes an
`llvm.`-prefixed name as the intrinsic it spells and attaches that
intrinsic's own attributes, so the module is the one the enum would
have built.

The speed then follows from the meaning rather than the other way
round.  NaN-as-identity makes `minimumNumber` associative and
commutative exactly, so LLVM's vectorizer may reduce an extremum loop
four lanes at a time — no fast-math, no reassociation of anything, and
the same value the sequential loop would have accumulated, down to
which zero it kept.  `math.vmin` over two million elements becomes
`fminnm.2d`.  A C twin written the ordinary way, `a < b ? a : b`, gets
no such licence: that expression decides a NaN by operand order, so
clang is stuck with a scalar compare-and-select chain.  A min-and-max
microbenchmark went from 2.96x the C twin to 0.54x, and `bench/stats`
— where the extrema are two of eleven passes over the data — from
1.23x to 1.08x.

The composition this replaced was `llvm.minimum` with the two NaN
cases selected around it.  It was correct, and it cost three dependent
floating-point instructions per element where the reduction needs one,
none of which the vectorizer would touch.

## What the module tells LLVM about the runtime

Every one of those calls used to be declared bare —
`declare i32 @luce_rt_len(ptr, ptr, ptr)` — which is the most
pessimistic thing LLVM can be handed: reads and writes all memory, may
unwind, may never come back.  `08_llvm/runtime_effects.zig` is the
one place
that says otherwise, with one arm per entry point and no `else`, so a
new runtime call is a compile error there rather than a declaration
that quietly goes out bare.

Three claims, each justified from the body of the corresponding export:

- **`nounwind`** — `libluce_rt` is Zig; a Luce trap is the `i32` a
  fallible call returns, not an unwind.
- **`willreturn`** — every export terminates, and a trap returns rather
  than jumping.
- **`memory(...)`** — per function.  `argmem` is what a pointer
  argument reaches: the `*Runtime`'s trap slot and counters, a borrowed
  `*const Value`, an out-parameter.  `inaccessiblemem` is the object
  table, the container storage, and the value arena, none of which
  generated code can reach — it holds objects as `i32` handles and
  Strings as `{ptr, len}` pairs it never loads through, and the only
  memory it ever *writes* is its own `alloca`s.  That separation is
  what distinguishes a reader (`luce_rt_len` —
  `memory(argmem: readwrite, inaccessiblemem: read)`) from a mutator
  (`luce_rt_append` — `readwrite` on both).

`luce_rt_report` is the one export that promises nothing: it hands
control to the host's trap callback, and a host is anybody's code.
`luce_rt_raise`, `luce_rt_unwound`, and `luce_rt_exhaust` are `cold`,
so the blocks that call them sink out of the straight-line path.

Arguments carry what is true of them at *every* call site, which is the
bar for an attribute on a shared declaration: a boxed `Value` is
`readonly nocapture nonnull noundef align 8 dereferenceable(24)`
because it is always an entry-block `alloca`; an out-parameter is the
same with `writeonly`; bytes that came from a *host* service get
`readonly nocapture` and nothing more, because the host fills those
slots and a host is not ours to promise for.  Two pointers the runtime
*keeps* — a trap's message and the function table — are deliberately
not `nocapture`.

A generated Luce function makes the matching promises about its own
hidden arguments: `%host` is `readonly nocapture nonnull noundef align
8 dereferenceable(sizeof(LuceHost))` — the service table is a
`const LuceHost *` for the whole run — `%rt` is `nocapture nonnull`,
and `%out` is `writeonly nocapture nonnull dereferenceable(n)`.

**What `inaccessiblemem` may cover moved when inline access
arrived.**  It means, in LangRef's words, memory *not accessible by the
current module*, and until generated code walked the object table that
described the whole heap.  It no longer does: the module loads the
table's base out of `%rt`, tests a row's `alive` byte, and loads and
stores array elements directly.  A false `inaccessiblemem` is not a
lost optimization but a miscompile — it would let LLVM conclude that
`luce_rt_append` cannot disturb an element this module just stored — so
anything that resolves a handle now names the *default* location
instead, and `inaccessiblemem` is left holding only what generated code
still cannot see: the value arena, a list's, map's or builder's own
buffer, and the unwind trace.

The distinction that survives is the one that pays.  A reader
(`luce_rt_len`) still promises to write nothing but its arguments, so
it cannot disturb an element store; a mutator (`luce_rt_append`)
promises nothing about the heap and is assumed to move everything in
it.  The parameter attributes are unchanged and do more work than the
summary: `readonly nocapture` on a borrowed box is what keeps a call
from being assumed to scribble on it.

## `T?` is the payload beside a bit

A `T?` lowers to `{T, i1}` for every payload — the payload, and one bit
saying whether it is there.  The four intrinsics are register moves and
nothing else: `none_value` is the payload's zero beside a clear bit,
`optional_wrap` sets the bit, `optional_unwrap` reads field zero, and
`is_none` is the bit inverted.  No call, no memory.  SROA takes the
pair apart in the entry block, so `parse_int(s) else 0` costs the parse
and a branch.

**docs/FAILURE.md proposed a sentinel for the heap case and it does not
work.**  The memo said a heap `T?` could be "the existing `i32` with the
null index".  Two things are wrong with that.  The small one is the
width: a handle became `{index, generation}` packed in an `i64` when
generational handles landed, so there is no `i32` any more.  The
disqualifying one is that the null index is already spoken for.  The
null handle is the *zero of an object-typed place* (S40) — a value that
is **present** and traps `null_object` when used — and a program can
put one inside a `T?` without a diagnostic:

```luce
func look(xs: list(long)?) -> bool:
    return xs == none

func main():
    var raw: list(long)          # the null handle
    print(string(look(raw)))       # interpreter: false — it is *there*
```

Absence on the interpreter is `Value.Tag.none`, a tag beside the
payload, so that program prints `false`.  A sentinel lowering would
print `true`, and the two engines would part company on the one program
that distinguishes them.  There is an agree test named for it.

Nor would the sentinel have paid.  long, double, bool, string and structs
have no spare value to encode absence in, so `{T, i1}` is forced for
six of the seven payloads; spending the seventh differently buys a word
that SROA was going to eliminate anyway, in exchange for the one
representation both engines can be checked against.

Where a `T?` has to become a `runtime.Value` — a struct field, an
argument crossing into `libluce_rt` — absence boxes as `Value.none`:
tag zero, no payload, no length, byte for byte what the interpreter
parks in the same slot.  **That is what makes ownership cost nothing.**
The runtime's ownership walks switch on the tag and fall through on
`none`, so "holding `none` owns nothing" (S43) is already true on both
engines with no code written for it, and a present `list(T)?` binds and
releases exactly as the bare handle does.  It is the one place the box
is filled entirely at the value site rather than partly in the entry
block, because neither its tag nor its length is a fact about the type.

## `T!` is the outcome word, and nothing else

A fallible call ends in three instructions and no memory traffic:

```llvm
  %outcome = call i32 @"luce.2.read"(ptr %host, ptr %rt, i64 %d, ptr %out)
  %trapped = icmp eq i32 %outcome, 1
  br i1 %trapped, label %unwind, label %returned      ; a trap still leaves
returned:
  %errored = icmp eq i32 %outcome, 2                  ; …an error is a branch
  br i1 %errored, label %handler, label %ok
```

**The success path reads nothing.**  No runtime call, no load of an
error flag, no save/restore protocol — the word the callee answered
*is* the channel, and `errored` is one `icmp` against a register.  That
is the whole reason the outcome is a word rather than a bit
(docs/FAILURE.md).

The two engines are the least alike here of anything the oracle
compares, and deliberately so.  The interpreter has no outcome word:
it keeps the error in `Runtime.raised` and `errored` reads that field,
because its frames are on an explicit stack and a `ret` there is a
pop.  Compiled frames are native frames and the value comes back in a
register, so that is where the answer lives.  Two mechanisms, one set
of answers — which is what `agree` checks, down to the leak census
after a caught error.

The message travels as `libluce_rt`, not as generated code:
`luce_rt_raise_error` takes the words and copies them, and
`luce_rt_raise_io` builds `cannot read PATH` itself.  Both copies are
mandatory rather than tidy: an error unwinds *through* releases, so
`error("x: " + string(n))` hands over bytes a statement temporary is
about to give back.  Building the words in one place is also what
makes both engines report the same sentence about the same path.

`file_read` is the one host service whose two outcomes do genuinely
different things, and it branches before it interns: the
out-parameters are filled only where the host said yes, and reading
them on the other side would read whatever was on the stack.

Nothing is recorded on the way out.  An error's **origin** — one
function index and one instruction index, resolved through the same
constant tables a trap's trace uses — is written once at the raise and
never appended to.  So the unwinding edge for an error carries no
`luce_rt_unwound` call at all: it empties `%out` and returns `2`.

That emptying is part of the convention rather than tidiness.  A
caller carries a fallible call's result across the branch on its
outcome, and the store that carries it stands *before* the branch — so
it runs on the failing path too, and a callee that wrote nothing would
leave it copying whatever the stack held.  Putting the store on the
callee's errored edge charges the path that already failed and leaves
the success path untouched, and it makes the compiled answer the one
the interpreter gives for free: a destination register nobody wrote is
still the `.none` its frame started at.

The slot that carries the value is the slot that **owns** it, and that
is where errors meet small-string optimisation.  An owning slot holds
a whole `runtime.Value`; a borrowing one holds the register shape,
which for a string is `{ptr, i64}` and cannot say the text is *inside*
the value it came from.  Carrying a result in a borrowing slot marked
short text as outside text, and the release at the end of the
statement freed a pointer into the frame (docs/STRINGS.md).

## `libluce_rt`

`src/luce/runtime.zig` plus
`runtime/{value,heap,containers,text,operators,exports}.zig`.  Luce's
semantics below the instruction level live here: the object heap,
ownership and serials (docs/OWNERSHIP.md), `list`/`map`/`array`/
`builder`, string storage and the string primitives,
`str`/`parse_int`/`parse_float`/`chr`/`ord`, checked arithmetic, and
the trap channel they all report through.

It builds as a real `libluce_rt.a`, installs beside the binaries, and
`cc` links it into every artifact.  **The oracle calls it too** —
`interpreter/machine.zig` keeps only the dispatch loop, the frame
stack, the traceback, and host effects.  There is exactly one
implementation of every semantic, and the specs are what prove it.

The C surface (`runtime/exports.zig`, some 58 `luce_rt_*` entry
points) holds to three conventions:

- **A fallible call returns `i32`; `1` means the program trapped.**
  That is the same edge generated code already uses for a Luce call,
  so there is no second propagation mechanism to keep in step.  `i32`
  rather than `_Bool` because `_Bool`'s width and extension rules are
  the one place LLVM's `i1` and the platform ABI disagree.
- **Results travel through an out-pointer.**  Nothing returns by value
  except a plain scalar answer.
- **A trap is announced once, when the program has stopped.**  A trap
  raised inline by generated code (`luce_rt_raise`) and one raised
  inside the library both land in the same place; every frame records
  itself on the way out (`luce_rt_unwound`); and `luce_rt_report`
  hands the host the code, the words, and the finished call trace
  together.  One channel, reporting the whole trap rather than half of
  it.

Allocation failure is not a Luce trap: no program can cause it
deliberately and none can catch it.  It becomes a status of its own,
so a host can tell "the program failed" from "the machine ran out".

A Luce value crosses the boundary as a pointer to a 24-byte
`runtime.Value` in an entry-block `alloca`.  The layout is asserted
against the Zig struct, so the two cannot drift.  Its tag is one byte
and the twenty-two after it are where a string's text lives when it
fits; generated code only ever *writes* the other form, and reads both
(docs/STRINGS.md).

## The published host ABI

`src/luce/08_llvm/abi.zig` is the contract and the only authority on
it; `abi.version` is the number a loader checks.  A compiled artifact
exports one symbol:

```c
int32_t luce_main(const LuceHost *host);   /* 0 ok, 1 trapped, 2 exhausted, 3 errored */
```

`LuceHost` is a flat `extern struct` of `context` followed by one
pointer-sized slot per service, in declaration order, which is exactly
the layout generated code walks with `getelementptr`.  The `Slot` enum
names those positions once so the lowering and the struct cannot
drift.

Effects reach the outside world through this table rather than through
undefined symbols, because an undefined symbol does not link into a
two-level-namespace macOS dylib — and a vtable is the shape
`interpreter.Host` already has for the oracle.  *Semantics* do not
come through it: lists, maps, strings, ownership, and the conversions
are `libluce_rt` calls, because they are the language rather than a
capability a host may withhold.

**Three rules hold the whole thing together:**

- **`trap` is required, and so is `raised`.**  `luce_main` calls each
  without a null check, once, after the program has stopped: `trap`
  with the trap's code, its words, its call trace, and the number of
  frames the trace's cap cut; `raised` with an uncaught error's code,
  its words, and the one position it carries.  A host that can run a
  program has to be able to say why it stopped, and those are two
  different sentences.
- **Every effect service is optional and fails closed.**  A null slot
  traps `host_unavailable` rather than touching anything — the same
  rule the interpreter follows, and what keeps a program given no
  host from touching anything.
- **Every fallible service answers an `Answer`:** `yes` (done, results
  in the out-parameters), `no` (the service said no — the file could
  not be read, the index is out of range; what that means is the
  caller's to decide), or `exhausted` (the host could not get memory,
  which is not a trap and ends the run the way the runtime's own arena
  failure does).  Strings a service hands back are borrowed for the
  call only; generated code copies them into the run's arena.
  Services that cannot fail — `term_rows`, `term_cols`, `clock_ms` —
  answer their value directly.

`finished` is the one outbound-only slot: the object leak census at
the end of a run that did not trap.  Memory is explicit in Luce, so
what a program did not free is part of what it did.

Compatibility: **fields are append-only and never reordered** (their
order *is* the layout), any change to an existing field's meaning or
signature bumps `version`, and a loader must refuse an older version
rather than tolerate it.

Version history, which is also the shape of the decisions: **2**
dropped `str_int` — a pure conversion belongs in the runtime, where it
is `luce_rt_str` — and added `finished`.  **3** added the remaining
host services (files, arguments, the terminal) and with them the
single `Answer` convention, which changed `print`'s return type and so
required the bump.  **4** made a trap a whole trap: `trap` carries the
call trace and is called once when the program has stopped, and
`call_depth` arrived beside it, because a trace of a runaway recursion
is only worth having if the recursion traps in the first place.  **5**
made the artifact tag name its machine the way Zig names one, so a
loader answers "is this mine?" without libLLVM in the process.  **6**
put a short string in the value itself.  **7** gave a run a third way
to end: `raised` arrived beside `trap`, and `luce_main` answers `3` for
a program that raised something nobody caught.  Three and not two —
docs/FAILURE.md predicted `2`, which `exhausted` had held since
version 3, and renumbering a published answer would have changed what
every existing loader believes.  **8** closed the host surface: nine
slots appended in one run — `read_line`, `print_error`, `clock_ms`,
`sleep_ms`, `env`, `file_append`, `file_delete`, `file_rename`,
`dir_list` — so a program can read a line, wait, and work with a
directory.  No field moved, and a run that calls none of them pays
nothing.  **9** moved no field and changed no signature: it gave
`key_read`'s `no` a meaning.  End of input — the keyboard has run dry
— which the program meets as `none`, exactly as `read_line` does.  It
had been answerable since version 3 under the shared `Answer`
convention and was read by nobody, so a host saying "no key will ever
come" and one saying "not yet" arrived as the same answer and the
program asking went round forever.  An artifact built against the old
reading spins at the end of its input, so it is rebuilt rather than
tolerated.

`key_text` has no slot of its own: it answers what the last `key_read`
carried, which the runtime remembers, so it fails closed on
`key_read`'s slot.  End of input clears it, which is why the lowering
clears both out-parameters before the call: a host that answers `no`
may leave them untouched, and the payload of a key that never came is
`""` and not the one before it.

Two shapes the version-8 slots settled, both of which stayed inside
the conventions already there rather than inventing new ones:

- **A directory listing travels as bytes.**  Every service that hands
  text back hands back a pointer and a length, and `dir_list` answers
  the names **NUL-separated in one buffer**; `luce_rt_names_list`
  splits it into the `list(string)` the program asked for.  A second
  convention — a vector of pointers, a callback per name — would be a
  second thing every host author has to get right, and NUL is the one
  byte a file name may not contain, so the joining loses nothing.
- **A service that may have nothing to say clears its out-parameters
  first.**  `read_line` and `env` answer a `string?`, and their `no`
  side leaves `text`/`length` untouched — so the lowering stores a
  null and a zero before the call and hands the answer to
  `luce_rt_maybe_text` as a `present` flag.  Two stores in front of a
  blocking call, and what they buy is that the load after it is never
  of whatever the stack happened to hold.  The runtime parks
  `Value.none` for absence, which is byte for byte what the
  interpreter parks, so a `T?` from the host means one thing on both
  engines.

## The lowering is total

There is no list here any more.  Everything a program can say lowers:
long, double, string, structs, all four container kinds, `T?`, `T!`,
ownership, the math builtins, and every host service.  The two things
that did not — `Bytes` and the evaluator ports — were cut rather than
grown (docs/ENGINE.md steps 1 and 2), because nothing constructed a
`Bytes` and nothing reached an evaluator.

`grep 'self.fail("' src/luce/08_llvm/lower.zig` is still the
authority, and what it finds now is entirely refusals of IR that could
only arrive damaged: a block without a terminator, arithmetic on a
type that has none, an entry function with parameters.  A `.lc` is
trusted like an executable, so those are how a forged one reports
itself instead of being `unreachable`.

Trap reporting is **not** on that list any more: a compiled trap
reports its code, its message, and its call stack with
`file:line:column`, and `--release` strips the lines and keeps the
names, exactly as docs/MODES.md describes and exactly as the oracle
does.

## The benchmark snapshot

`bench/run.sh`, Apple M4 Max, best of five, C at `-O3 -march=native`
against Luce `--release` under `loom run` from a warm artifact.  Both
sides include process startup; `compute` is the same numbers with the
do-nothing floor taken off each, which is the ratio a code-generation
change moves.  Absolute times mean nothing off this host — for a
before/after, use `bench/compare.sh GIT-REF`, which interleaves the
two on the machine in front of you.

**Taken at the `byte`/`short`/`half` step (docs/TYPES.md step 5-6).**
This table is the one number: where a document quotes a benchmark row
it quotes the `compute` column here, and says which column it is.

| benchmark | C        | luce     | luce/C | compute |
|-----------|----------|----------|--------|---------|
| loops     |  78.8 ms |  81.3 ms |  1.03x |   1.02x |
| math      | 135.0 ms | 105.8 ms |  0.78x |   0.77x |
| strings   |  20.1 ms |  50.6 ms |  2.51x |   2.74x |
| arrays    |  42.5 ms |  45.3 ms |  1.06x |   1.05x |
| arrays32  |   7.7 ms |  41.8 ms |  5.44x |   8.14x |
| matmul    |  10.3 ms |  11.3 ms |  1.09x |   1.03x |
| matmul32  |   6.5 ms |   7.5 ms |  1.15x |   1.07x |
| stats     |  31.3 ms |  33.2 ms |  1.06x |   1.04x |
| floor     |   3.0 ms |   3.7 ms |      - |       - |

The six 64-bit rows are unchanged within noise from the previous
snapshot at `f333e12`, which is what D7 required of them: the 32-bit
rows were *added* beside them and neither the `.luc` sources nor the C
twins of the originals were touched.

`strings` is allocation-bound rather than code-generation-bound.
Everything else at 64 bits is at parity or ahead, and `math` is ahead
because Luce's transcendental calls land in the same libm C's do while
the surrounding loop vectorizes.

### What the two new rows measured

**`matmul32` is the good news and it is unremarkable, which is the
point.**  1.07x compute against 1.03x for the `double` twin: the
binary32 inner loop vectorizes on both sides, four lanes where the
64-bit one got two, and Luce keeps pace.  Whatever the resize cost, it
did not cost this.

**`arrays32` is 8.14x, and it is not a 32-bit problem.**  The
measurement that says so:

| dot product | C       | luce    |
|-------------|---------|---------|
| `int32`     |  6.2 ms | 41.8 ms |
| `int64`     | 18.1 ms | 41.1 ms |

**Luce is scalar at both widths and C is vectorized at both.**  The
narrow integer buys Luce nothing here — 41.8 against 41.1 ms is noise
— while it buys C a factor of 2.9, so the *ratio* gets worse exactly
because C got better.

The cause is **checked integer arithmetic**, and this row is the first
in the suite to price it.  Every `+` and `*` in Luce carries an
overflow test, so an integer reduction cannot be reassociated and
cannot be vectorized; the loop stays one element per iteration with
two branches on top.  C's `int32_t` addition wraps on overflow, which
is undefined behaviour it is free to assume never happens, so LLVM
reassociates the sum and fills four lanes.

That is also why no existing row showed it.  `arrays` is a *float*
dot product, and a left-to-right float reduction cannot be
reassociated **by C either** — so both sides stay scalar and the row
sits at 1.05x.  `loops` and `stats` are checked integer loops too, but
neither is a reduction C can vectorize.  It took an integer reduction
to separate the two, and that is what `arrays32` is.

**Nothing here is a regression and nothing here is fixed by widening
back.**  It is a standing cost of the safety guarantee, now measured
rather than assumed, and the options if it is ever worth spending on
are the ordinary ones: prove the bound and drop the check, or offer a
reduction that is allowed to reassociate.  Neither is in this step,
and both are language decisions rather than code-generation ones.

> **What the previous snapshot said, and why it was replaced.**  The
> table here read `20.6 / 47.4 ms, 2.31x / 2.49x` for `strings` and
> had done since `48453a4` — fifty-one commits back, and *before*
> copy-on-store, small-string optimisation and `T!` all landed.  Two
> runs at `f333e12` put Luce's `strings` at 53.5 and 53.7 ms with
> every other row and the do-nothing floor unmoved, so the difference
> is that row and not the host.  `docs/STRINGS.md`'s own closing
> measurement — `2.71× C → 2.68× C` — was the figure that had stayed
> honest, and it agrees with today's within noise.  A stale row in
> the table every other document quotes is the expensive kind, so it
> is refreshed here rather than annotated.

## Building

libLLVM is a hard build dependency of **the `luce` compiler**, because
the one code generator calls it in process.  `build.zig` finds it by
asking `llvm-config` — on `PATH` or in the usual Homebrew and
distribution prefixes — for its include directory, library directory,
libraries, system libraries, and C++ runtime.  Point the build
elsewhere with:

```sh
zig build -Dllvm-config=/path/to/llvm-config
```

`loom` does not link it and must not start doing so; the dependency is
confined to the `emit` module (above), and `otool -L build/loom` is
how that stays true.

**`cc` is a dependency of building at all**, not only of testing.
`build.zig` compiles the nine bundled programs and the six benchmarks
with the freshly built `luce`, and under a native `.lc` that compile
is a link.  Each one is pointed at the *installed* `libluce_rt.a`
through `LUCE_LIB` — a configure-time path, because a `Run` step's
environment cannot take a lazy one — and the library is a declared
file input, so a change to the runtime rebuilds every program that
carries a copy of it.  `zig build test` therefore installs
`libluce_rt.a` as a side effect, which is the price of testing the
link.

## Where this goes next

**Cross-compilation** is the largest thing missing, and the missing
piece is not the code generator.  `emit.zig` already registers
AArch64, X86 and WebAssembly and takes a triple as a parameter;
`src/apps/luce/object.zig` hard-codes `emit.hostTriple()` and the CLI
has no `--target`.  What is genuinely absent is **the link**: `cc`
links for the host and `libluce_rt.a` is built for the host, so
shipping to another machine means one `libluce_rt` per target and a
linker willing to take it.  `zig cc` is the obvious answer, and Zig is
already a build dependency.  Until then a `.lc` is refused by name on
a machine it was not built for, which is the right failure.

**A shared `libluce_rt`** is the other one, and it is a size decision
taken knowingly rather than an oversight.  Every artifact statically
links the runtime, so one is ~683 KB whatever the program says and the
nine bundled programs total 6.1 MB.  A dylib beside the binaries would
collapse that, and would trade a self-contained file that runs
anywhere the machine matches for an rpath and a version-matched
install.  That is a change to what an artifact *is*, and it is not
made here.

The interpreter's dispatch loop does not go anywhere.  It is the
differential oracle the specs run every program against, it ships in
nothing, and its cost is the ~0.3 s of interpreted arms inside a
four-minute suite (docs/ENGINE.md Hat 1).

One smaller thing this path leaves open on purpose:

- **Nothing sweeps `.lc` files.**  They sit beside their programs and
  are deleted with them; the `TMPDIR` copies are the session's to
  clear.  A cache that grows without bound would need a policy, and a
  content-addressed file next to the thing it was addressed from does
  not.
