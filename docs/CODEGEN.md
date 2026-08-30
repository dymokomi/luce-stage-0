# Code generation — the LLVM path

Luce has one code generator.  It lowers the typed Luce IR to LLVM IR,
hands that to libLLVM, and gets back machine code.  This file is both
the decision record for that seam and the description of what is
there.

The path is **the only one**: `luce build` writes a standalone executable
named from the source, `--emit=library` writes the loadable `.lc` artifact,
and `loom run FILE.lc` opens and calls machine code.  The interpreter is
no longer an engine — it ships in nothing and survives as the
differential oracle in the test suite (docs/ENGINE.md).  What follows
says exactly how far this path reaches and how it reaches a person.

Where this file compares the compiled answer against "the
interpreter", it means the oracle: the second implementation the specs
run every program on and compare against, not something a user can
select.  There is nothing to select.

## The pipeline

```text
FILE.luc → lex → parse → semantics → typed MIR → optimize
                                             ↓
                        codegen/builder (vendored)  (codegen/lower.zig)
                                             ↓
                                        LLVM bitcode
                                             ↓
              libLLVM: parse, default<O1|O3>, emit  (codegen/emit.zig)
                                             ↓
                                  FILE.o  (relocatable object)
                                             ↓
                            cc  (src/apps/native.zig)
                                    ↓                ↓
                            FILE.lc             FILE (executable)
```

```sh
luce build FILE.luc                 # FILE      — a shell runs it (default)
luce build FILE.luc --emit=library  # FILE.lc   — loom loads and calls it
luce build FILE.luc --emit=object   # FILE.o    — you link it
```

The object is built for the host triple, is position-independent,
exports `luce_main` and its artifact tag, and declares no undefined
symbols beyond `libluce_rt`.  That last claim is proved by the link
itself, which is why linking is part of the shipped path rather than
only of a test.

`libluce_rt` in turn declares none beyond the C platform libraries.
Two are worth saying out loud because they decide a link line: the
runtime owns workers, and float `%` calls `fmod`. Darwin keeps threads
and math in libSystem, so a bare `cc` link has both. Linux needs the
portable driver flags after the runtime archive, and a link you write
by hand out of `--emit=object` has to include them too:

```sh
cc -o FILE FILE.o lib/libluce_start.a lib/libluce_rt.a -pthread -lm
```

On macOS, add the window host frameworks when linking a standalone program:

```sh
cc -o FILE FILE.o lib/libluce_start.a lib/libluce_rt.a \
  -framework AppKit -framework Metal -framework QuartzCore
```

`luce build` adds these flags for you. They are needed because the
standalone start archive carries the same `std.ui`/`std.gpu` host as `loom`.

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
be run or could not deliver its output, and anything else is a program
that called `exit(n)`** — a run that ended `.exited` answers the
program's own status, low eight bits (`start.zig`'s `finish`), because
`exit` is the program choosing a number and not a failure.  A trap and
an error being
two different sentences about a program (docs/FAILURE.md), which is
why a script reading `$?` can tell them apart without parsing stderr.  Terminal services in a non-loom
binary were the open question, and null slots (fail closed, trap
`host_unavailable`) would have been defensible — but they would make
"the compiled program behaves identically" true of one runner and not
the other, and two of the ten bundled programs draw on a screen.  A
program's behaviour must not depend on who started it.

For that to be a small library rather than a copy of the compiler,
`abi.zig` takes the trap channel's C shapes from `runtime/trace.zig`
rather than from the `runtime.zig` barrel, which force-analyzes the
whole `luce_rt_*` surface.  `libluce_start.a` therefore has exactly
two undefined Luce symbols — `luce_main` and `luce_artifact` — and no
second copy of the runtime to collide with the real one at link time.

**How an artifact says what it is.**  It exports `luce_artifact`, a
constant `artifact.Artifact`: a magic, the tag's own layout version,
the host ABI version, the machine, a hash of the serialized module it
was built from, what generated the code, and whether it kept its
origins.  A loader reads that *before* it calls anything, and refuses
by name — wrong machine, wrong ABI, wrong code generator, stale
program — because a native artifact is not portable and a file name
cannot be trusted to say so.  Without the tag, a `.lc` copied between
machines is a file that loads cleanly and crashes with no explanation.

**And the tag is read before the file is loaded at all.**  It used to
be reached through the exported symbol, which meant `dlopen` came
first and the *platform* loader had the first word — and what a
platform loader says about a broken file is not a sentence.  A `.lc`
truncated anywhere from a quarter of the way to nearly all of it opens
on Linux and **runs**, because the loader needs only the program
headers and the segments they name; further in, it maps a segment past
the end of the file and the first touch of that page is a SIGBUS with
nothing to say.  On macOS dyld declines, and what reached the person
was dyld's shrug relayed as though it were an answer about the
program.  So the tag now sits in a section of its own —
`__LUCE,__artifact` on Mach-O, `.luce_artifact` on ELF, spelled once in
`artifact.section` — and `src/apps/native.zig` walks the file's own
container headers to find it: every offset checked against the file's
length before it is followed, **every** segment or section checked and
not only the tag's, so a file cut off after the tag is caught too.
Nothing is mapped, nothing is relocated, nothing runs.  A file whose
headers describe bytes it does not have is `damaged` — an answer about
the file, which is the true one — and `dlopen` gets its turn only once
the tag has agreed.  Both containers are read on both platforms,
dispatched by the file's own magic rather than by the host, which is
what makes "it was built for aarch64-linux-gnu, and this machine is
aarch64-macos-none" a sentence a macOS loom can say about a Linux
artifact.  Nothing in the tag is a pointer, for the same reason: in a
file nobody has loaded there are no addresses, only relocations nobody
has applied, so the machine's name is a run of bytes inside the tag
(`format` 3).  An artifact with no such section is refused as not an
artifact — and it is stale by `generator` anyway, since no compiler
that emits the section shares an identity with one that did not.

**The tag is `codegen/artifact.zig` and not `abi.zig`**, and the split
is the point: `abi.zig` is what generated code and a host agree on,
while the tag is what a *loader* reads before it can believe any of
that — including which host ABI the code was generated against, which
is one field inside it.  So the two carry their own version numbers
and move on their own schedules, and their consumers are disjoint: the
loader sites read the tag and never touch `LuceHost`.

The machine is `artifact.machine` — `aarch64-macos-none`, architecture,
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

A `.lc` **is** the loadable artifact: `luce build NAME.luc --emit=library`
writes one and `loom run NAME.lc` opens it.  What is cached is the compile
that loom does on a person's behalf — `loom luce NAME.luc` puts the result
beside the source, as `NAME.lc`, exactly the library file it would have
written, so a second run finds a warm one.  It is deletable with
the program and visible in a listing, which a hidden cache is not.
When there is nowhere to write beside the program — a read-only
directory, or a program with no path at all, like the editor embedded
in loom — the artifact goes to the session's own `TMPDIR` under its
hash.  (`TMPDIR` rather than `/tmp`: the file gets `dlopen`ed, and a
world-writable directory is not where that should be decided.)

**The key is content, never a timestamp.**  The tag carries
`artifact.sourceHash` of the serialized module, so a rebuild that produced
identical bytes hits, a program whose bytes changed misses, and a file
restored from a backup with an old mtime does not quietly win.  That
is PEP 552's answer rather than PEP 3147's.

**And the content is the compiler's as well as the program's.**  A
`.lc` holds machine code, and which machine code depends on two
independent things: the program, and whatever turned it into
instructions.  `source_hash` answers the first.  `artifact.generator`
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
  `src/luce/codegen/`, plus the barrel.
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
of several).  Absolute times mean nothing off this host; what the
table is for is the *shape* — warm is two orders of magnitude under
cold, and cold is paid once per change to the program.

| program | warm | cold (compile + link + first load) |
|---------|------|------------------------------------|
| hello   | 4.0 ms | 137 ms |
| editor  | 4.0 ms | 291 ms |
| loops   | 84 ms  | 233 ms |
| matmul  | 12 ms  | 159 ms |
| strings | 52 ms  | 230 ms |

Warm startup is process start and `dlopen`, and nothing else.  A cold
run — a source file loom has not compiled before — pays one `luce`
process, LLVM's quick pipeline (compile-and-run is a debug build,
docs/MODES.md), one link, and the first `dlopen` of a binary
the OS has never seen, which on macOS is the largest single term of
the four (89 ms of `sort.luc`'s 155).  It is
paid once per change to the program.

### loom does not carry a code generator

**`luce` is the compiler and links libLLVM; `loom` is the environment
and does not.**  When loom meets a program with no current artifact it
runs the `luce` binary over the serialized module it is already
holding.

The reason is dyld.  Homebrew's `libLLVM.dylib` is 164 MB, and a
process that names it maps and binds all of it before `main` — 5.7 ms
on this host, measured against an otherwise identical binary, with
zero LLVM functions ever called.  **That number is the shared-libLLVM
case**, which is what a system LLVM gives you; `./vendor-llvm.sh`
links a pinned LLVM statically instead and has no dylib to bind, so it
pays the cost differently.  Either way the argument is the same, and
it is about what `loom` must not carry rather than about how the one
that does carry it is linked.  loom's whole job is starting
programs, so it paid that on every single invocation: warm runs, cold
runs, and `loom` with no arguments alike.  Against a C do-nothing
binary at 2.4 ms, loom's floor was 8.8 ms; it is now 3.1 ms, and
`bench/matmul` went from 1.7x of its C twin to 1.08x with no change to
a single generated instruction.

What makes the split possible is that almost nothing needs libLLVM.
`lower.zig` builds LLVM IR with the vendored builder
(`codegen/builder/`), which is pure Zig and links nothing; the
artifact tag names its machine with
`artifact.machine` rather than an LLVM triple, so a loader can check it
with no library at all.  Exactly one file calls the C API —
`codegen/emit.zig` — and it is its own build module (`emit`) that only
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
  (`mir/module.zig`), so the hash matches by construction.  `luce
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

**IR construction uses the vendored builder** — `codegen/builder/`,
the pinned standard library's pure-Zig `std.zig.llvm.Builder` taken
in-tree so it can attach metadata to loads, stores and calls, three
files whose every deviation carries a `LUCE:` comment — and links
nothing.  `emit.zig` is the
only file in the tree that touches libLLVM, and it uses the narrowest
tier of the C API: parse a bitcode buffer, make a target machine, run
a textual pass pipeline, write an object.  That is the tier LLVM's own
developer policy describes as stable; IR *construction*, the part that
has broken repeatedly across releases, stays in-tree.  Being one file
is also what makes it one *module*, which is what keeps libLLVM out of
loom.

**Both optimizer knobs move together**, and the interesting thing is
that they used not to.  A release build's pass pipeline is
`default<O3>` for one argued reason — nontrivial loop unswitching,
which O2 disables and which is what lifts a bounds check out of a loop
so the vectorizer can have it (`Options.passes`) — while the target
machine was left at `LLVMCodeGenOptLevel` 2, never argued and simply
unnoticed, so instruction selection and register allocation worked
less hard than the pipeline that fed them.  Raising it was A/B'd on
every `bench/` row (`bench/compare.sh`, twice): every row inside the
round-to-round spread, with the signs flipping between runs.  It is
kept anyway, and not for the speed — two knobs that both mean "how
hard to optimize" pointing at two numbers is a question a reader has
to answer twice, and the honest answer to "why O2 here" was that
nobody had chosen it.

The same rule decides the debug pair: `default<O1>` with the machine
level at `none`, which is what selects FastISel over the SelectionDAG.
One question — how hard is this build working? — asked once and
answered on both knobs (`src/apps/luce/object.zig`).

**The stage directory is `codegen/`, not `llvm/`.** Zig derives symbol
names from source paths, and LLVM reserves every symbol beginning
`llvm.` for its intrinsics. A top-level `llvm/abi.zig` would therefore
make Zig abort with "llvm intrinsics cannot be defined!". `codegen` is
also the more durable boundary: it names the compiler responsibility,
while LLVM names the current implementation behind it.

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

### Function values and indirect calls

A function value is a **two-slot `runtime.Value` run** (docs/BINDING.md
D12): slot 0 holds the `i32` index into `Program.functions`, slot 1 the
receiver the value carries or `none`.  No address is carried through
the language.  `const_function` builds that run with
`luce_rt_struct_make`, the same call a struct literal makes, so the
runtime learned a shape and not a semantic — it copies, releases and
walks the run with the code it already had for struct field runs.  The
run is built the same way whether a receiver is there or not, which is
what lets a `func(...)` place hold a plain function, a lambda and a
bind without any reader distinguishing them.

`call_indirect` reads slot 0, checks the run is really there and the
index is really a function, performs the same call-depth check as a
direct call, loads one pointer from the module's `luce.function_table`,
and calls it with the same `%host`, `%rt`, `%depth`, **a pointer to
slot 1**, the value arguments and the optional `%out`.  The returned
outcome takes the same unwind edge.  A fallible function cannot become
a value, so the indirect shape has no error edge to lose.

**The table holds adapters, not functions.**  A call site cannot know
whether the value in its hand carries a receiver — the type does not say
— and a C signature is chosen at compile time, so every entry has the
same shape with the receiver slot in it: `luce.bound.N` unboxes that
slot into the callee's parameter zero when the value is a bind and
ignores it when it is not.  One row per Luce function in program order,
null for every function no value ever names (unreachable, because the
adapters were collected from the same `const_function` instructions an
index can only have come from).  It is a private constant emitted only
if a function value is made, so a program of direct calls carries no
function-pointer machinery.  The cost is one extra call frame per call
*through a value*; the alternative was two calling conventions at a site
that cannot tell them apart.  A second lazy table holds the
corresponding names for `str(f)`; a named function gives its
qualified name, a bind gives the method's qualified name, and a lambda
gives the distinct compiler name synthesized from its source place.
The interpreter needs no adapters — it has the program in front of it
and prepends the receiver to the argument run — and uses the same
indices against its `mir.Function` table, which is why the differential
specs exercise one representation rather than two unrelated dispatch
rules.

The MIR verifier has two iterative containment checks: one for direct
struct layout cycles, and one combined graph for anonymous heap-type
shapes and nested function signatures.  Keeping structs out of the
second graph permits a legal `Node` through `list[Node]`, while the
combined anonymous graph still catches heap/signature cross-cycles.
Both checks run before printing or lowering can recursively expand a
type — source cannot make these malformed rows, but a hand-written or
fuzzed `.lcm` can reach the decoder and must be refused without hanging
it.

Pruning follows `const_function` exactly as it follows a direct call.
Otherwise an apparently unreachable comparator could be deleted while
the integer that names it survived, turning a valid value into an
out-of-range indirect call.

### Program-root constant containers

Verified MIR has two constant pools.  `constants` holds text bytes;
`container_constants` holds one row per written flat list, map, or
rank-1 array construction, including its heap type, folded values,
declaration name and debug origin.  Equal rows are deliberately not
content-interned because object equality is identity.  `const_container K`
loads the handle in runtime root slot K, so aliases and defaults of
one construction share while separately written equal constructions do
not.

`prune` follows surviving `const_container` instructions after dead
instruction removal, compacts the pool, and remaps the indices.  An
unused table therefore emits neither data nor startup work.  The pool,
the instruction, their wire tags, and `immutable_object` moved the
serialized module to **format 33**; none is a host service, so
`abi.version` remains **13** at that point in the format history.
Later host services and instruction changes moved both forward under
their versioned layouts — the module format to **47** and the ABI
to **19** — each bump refusing a stale artifact by name rather than
migrating it.

Every generated entry path calls one private `luce.constants`
materializer before user code.  It constructs rows through the same
stable runtime operations ordinary containers use, publishes each
finished handle into the program root, then freezes the root table.
Failure discards the unpublished row and every root already published;
in debug mode the synthetic trace frame names the declaration.  A
worker creates a runtime of its own and calls the same materializer, so
roots never cross the worker boundary.  The interpreter performs the
same eager prologue against `libluce_rt`, which is why the executable
specification compares one representation rather than two.

The static analyzer rejects a write while it can still see the root.
Generated code carries the dynamic half for a parameter-hidden root:
runtime mutators resolve through `resolveMutable`, and inline list or
array stores read the row's `constant` flag before touching the element.
The check stays next to the existing null, generation and bounds checks
and traps `immutable_object`.

`codegen/mutability.zig` derives when that flag check may be omitted from
the final verified MIR rather than trusting a bit a decoded module could
forge.  Its fixed-point plan is deliberately conservative: parameters,
inout slots, calls, `const_container`, and every other heap-producing
instruction may name a constant; only `heap_new` values that remain
provably fresh while flowing through non-parameter locals do not.  Thus
fresh inline mutations recover the branch-free path, while aliases,
parameters, calls and hostile MIR retain the runtime backstop.  ARC
changes how those references live, not where program constants can come
from.  This compiler-internal proof changes neither the serialized format
nor the host ABI.

The proof also guards performance: without it the constant-flag load sat
inside `matmul`'s innermost loop and stopped vectorization.  The generated
ARM64 code now carries two-lane `fmul`/`fadd` again.  An interleaved A/B
against the last pre-ARC compiler (`8c06013`) measured raw deltas of
loops -0.0%, math +0.6%, strings -5.3%, arrays -0.7%, arrays32 +2.2%,
matmul +1.8%, matmul32 +0.1%, stats +1.3%, and lists -0.3%.  The whole
suite is therefore within same-host noise, with strings modestly faster.
Program roots are omitted from the user leak census while live and
released last at runtime teardown.

Locals are entry-block `alloca`s that mem2reg promotes.  Every
`alloca`, including scratch slots created deep in the walk, is emitted
in the entry block, so nothing accumulates inside a loop.

### Writing methods and the inout receiver

A reading method is an ordinary direct call whose logical first
argument is the receiver value.  A writing method is different in the
one place that matters: MIR uses `call_inout { function, receiver,
arguments }`, where `receiver` is a caller local and `arguments`
contains only what the source wrote between parentheses.  The callee's
logical parameter zero is an `inout` local rather than storage owned by
its frame.

LLVM carries that edge as one internal descriptor: a pointer to the
caller's slot plus the owning frame's serial and local number.  The
callee aliases the pointer, uses the inherited identity for object
binds and unbinds, and does not clean the slot up when its frame ends.
A writing method that calls another writing method on `self` forwards
the same descriptor, which is what keeps an object-carrying receiver's
owner unchanged through nested calls.  The interpreter mirrors the
same three fields in its frame.

This is genuinely in-place, not the retired copy-in/copy-out result
convention: a store performed before an error remains visible while
the error unwinds.  It is also entirely internal.  `call_inout` and
the local flag first moved the serialized module to format 32;
program-root constants then moved it to 33, and later host services
and instruction changes carried both forward to the current **format
55** and **host ABI 24**.

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

A `list` element, an `array` element and the string primitives are
**generated, not called**.  `xs[i]`, `grid[r, c]`, `len(xs)`,
`a.dim(k)`, `xs.append(v)`, `s.byte_at(i)`, `s[a:b]` and `len(s)` all
lower to the bounds check and the load they are, with no boxed
subscript and no call.

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
`array[f64, _]`, which collapses the runtime's four-way switch to one
arm before an instruction is emitted.

Three things make it pay, and all three are needed together:

- **The row is walked directly.**  `runtime.layout` (in
  `runtime/heap.zig`) gives the byte offsets of the object table's
  base, a row's `generation`, an array's `dims`, and the shared
  element run's `pointer`, `capacity` and `count`.  Every one is
  measured from the Zig types with `@offsetOf` and checked against a
  real `Runtime` by a test beside them, so the two cannot drift.  A
  container's storage is a field of the row rather than a payload
  inside the `data` union for exactly this reason: Zig promises a
  layout for a struct field and none for a tagged union's payload.
- **Elements are stored as themselves.**  An `array[f64]` is `f64`s,
  a `list[u8]` is bytes, an `array[bool]` is bytes; only Strings,
  structs and objects keep the 24-byte slot.  `Value` is the
  *boundary* type — how an element crosses into a caller — never the
  storage type. Reading an `f64` element becomes one `ldr d0`, the
  memory traffic is a third of a boxed array's, and an array of
  untagged doubles is the only kind that can ever reach a SIMD unit or
  a GPU.
- **Which kind is a fact of the type, not of the builder.**  A
  `list[i64]` is `i64` cells whether `list[i64]()` made it or
  `m.keys()` did (`runtime/containers.zig`'s `emptyList`), so a cell's
  width is a compile-time constant here and there is no kind to branch
  on.  The two operations that could once produce either — `m.keys()`
  and `m.values()` — take the element zero the way `newList` and
  `newArray` already did, for the reason those two take one: the
  element *type* lives in the program's table and the runtime does not
  know it, and a zero's tag is that type.  A per-access branch on the
  object's kind would have been the alternative, and it would have hid
  the problem rather than fixed it.
- **The resolution leaves the loop** (`codegen/loops.zig`).  Resolving
  at every access leaves four loads in front of every element read,
  and LICM cannot lift them: the loop also *stores* an element through
  a pointer loaded out of the row, and nothing in the IR says the two
  do not overlap.  Saying otherwise wants TBAA or `!alias.scope`, and
  `std.zig.llvm.Builder` attaches metadata to branches and to nothing
  else.  So the compiler does it: the row is read once in the
  preheader of the outermost loop that cannot disturb it — nothing
  that attaches an object, frees one, or replaces a container's
  storage (`optimize.effects.viewStable`).

  **The metadata exists, and the honest number is: it moves nothing
  this suite measures.**  The IR builder is vendored (`codegen/builder/`, three
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
without deciding anything about it — a null handle reads a private
retired row, zeros except for `runtime.retired` where the generation
sits, so the loads are safe unconditionally — and every access still
tests the handle for null and the row's generation against the
handle's own before it touches an element.  A trap fires at exactly the instruction that owes
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

### The container whose buffer moves

The path above was written for the container whose storage never
moves, and said so.  A `list`'s does move, under `append` — and it is
on the inline path all the same, because **the invalidation rule was
already written down and already enforced**.

It is one sentence: *a resolved view dies at every instruction that
could move a buffer* — every call, every `append`, every `insert`.
That is exactly `optimize.effects.viewStable`, which has answered
`false` for `append_value` and `insert_value` since it was written and
gives that as its reason ("a list's elements are read through the same
row, so this stays conservative"), and it is what ends the basic block
a view lives in.  Nothing is carried across one, so a list needed no
new analysis: `len`, `xs[i]` and `xs[i] = v` are the row walk, the
bounds check and the load, and a read, a strided read or an in-place
transform lifts out of a loop under the same gate the array path
stands on.  A loop that could grow a list never reaches the lifting in
the first place, which is why "cache the pointer and hope" was never
the question.

**`append` is the other half, and it is the half that paid.**  Load
the count and the capacity; when the element fits, store it and bump
the count; call `luce_rt_append` only to grow.  Three things about it
are worth writing down:

- **The room is compared in bytes, not in elements.**
  `Elements.ensureCapacity` grows a byte length geometrically and does
  not leave it a whole multiple of the width, so `count < capacity` is
  a division — the very division the bytes run measured on `strings`
  and removed.  `(count + 1) * width <= bytes.len` is the same
  question with a constant multiply.
- **The gate is `ownsNothing`, for a different reason than
  `index_set`'s.**  A store into a container frees the element it
  replaced; an append replaces nothing and only *adopts* what arrives.
  So what the inline path needs is that there is nothing to adopt,
  which a scalar satisfies.  A `str`, a struct and an object go on
  calling the runtime, which is the one place that walk is written.
- **The checks do not move.**  `null_object`, at the instruction that
  owes it, exactly as the call made it; the growing arm resolves a
  second time, which costs one
  row walk on the path that was about to allocate anyway.

`map` is deliberately not on the inline path: a hash probe is genuinely
call-worthy.  Neither is `find_byte`, which is a vectorized `memchr` in
the runtime and would be slower unrolled here.

## The extrema, and a vectorization that is parked

`min`, `max` and `clamp` on the float types are generated too — an
explicit compare-and-select sequence per element (`emitExtremum` in
`lower.zig`) that spells out the one semantic `operators.pick` in
`libluce_rt` states: keep the non-NaN operand, answer an ordered pair
by comparison, and order the signs on a tie, so `min` is negative when
either zero is and `max` only when both are.  `clamp` is the two
composed in the runtime's order.  The runtime writes that sentence out
rather than leaning on Zig's `@min`/`@max`, because those lower to
`llvm.minnum`/`llvm.maxnum`, which leave the signed-zero order to the
target — a zero tie decided by the host's instruction set is not a
semantics — and the spec "min and max reductions over an array agree,
signed zeros and all" holds both engines to the written one.

This section used to be called "why a `min` reduction vectorizes",
and recorded the previous lowering: `llvm.minimumnum` — IEEE 754-2019
`minimumNumber`, `-0.0` below `+0.0` and NaN as an identity — which
says Luce's exact sentence as one intrinsic, is associative and
commutative exactly because of it, and therefore let the vectorizer
reduce an extremum loop four lanes at a time with no fast-math
(`math.vmin` over two million elements became `fminnm.2d`; a
min-and-max microbenchmark went from 2.96x the C twin to 0.54x, and
`bench/stats` from 1.23x to 1.08x).  It was retired when its x86-64
lowering was observed choosing the other zero on a tie — and able to
reverse an ordinary ordered pair — which is a miscompile, not a
slowness.  **The meaning is not negotiable per target, so the win is
parked, not abandoned**: the intrinsic is the right emission again the
day its lowering can be trusted on every target `luce` builds for,
and the compare/select chain is the portable spelling until then.
The snapshot table below is the current price in `stats`.

## What the module tells LLVM about the runtime

Every one of those calls used to be declared bare —
`declare i32 @luce_rt_len(ptr, ptr, ptr)` — which is the most
pessimistic thing LLVM can be handed: reads and writes all memory, may
unwind, may never come back.  `codegen/runtime_effects.zig` is the
one place
that says otherwise, with one arm per entry point and no `else`, so a
new runtime call is a compile error there rather than a declaration
that quietly goes out bare.

Three claims, each justified from the body of the corresponding export:

- **`nounwind`** — `libluce_rt` is Zig; a Luce trap is the `i32` a
  fallible call returns, not an unwind.  Only final `report` and
  `report_error` conservatively withhold the promise because arbitrary
  host callbacks own their control flow.
- **`willreturn`** — a trap returns rather than jumping, but host/worker
  callbacks, the effect-lock wait, and release paths that can close a
  file or join a task may not.  `copy`, `list_slice`, and `map_values`
  also withhold the promise: the cycle guard makes their graph
  walk finite, but native recursion depth remains data-dependent and has
  no fixed return bound.  Exactly twenty-three
  exports withhold the attribute, pinned as a closed set in
  `runtime_effects.zig`; every other export is asserted to keep it.
- **`memory(...)`** — per function.  `argmem` is what a pointer
  argument reaches: the `*Runtime`'s trap slot and counters, a borrowed
  `*const Value`, an out-parameter.  `inaccessiblemem` is only private
  storage generated code cannot reach: the value arena, list/map/builder
  buffers, and the unwind trace.  The default location includes the
  object-table rows and array dimensions/elements because inline
  container access reaches those directly.  That separation still lets
  a reader such as `luce_rt_len` promise not to disturb an element store,
  while a mutator such as `luce_rt_append` makes the general read/write
  claim.  The detailed boundary is pinned below.

`luce_rt_report` and `luce_rt_report_error` are the two exports that
promise nothing — same attributes, same reason: each hands control to
a host callback, and a host is anybody's code.  Not the memory it
touches, not that it comes back, not that it does not unwind.
`luce_rt_raise`, `luce_rt_unwound`, and `luce_rt_exhaust` are `cold`,
so the blocks that call them sink out of the straight-line path.

Arguments carry what is true of them at *every* call site, which is the
bar for an attribute on a shared declaration: a boxed `Value` is
`readonly nocapture nonnull noundef align 8 dereferenceable(24)`
because it is always an entry-block `alloca`; an out-parameter is the
same with `writeonly`; bytes that came from a *host* service get
`readonly nocapture` and nothing more, because the host fills those
slots and a host is not ours to promise for.  Exactly one pointer the
runtime keeps — `luce_rt_open`'s function table — is deliberately not
`nocapture`.  Trap words are copied into runtime-owned storage rather
than retained from the caller.

A generated Luce function makes the matching promises about its own
hidden arguments: `%host` is `readonly nocapture nonnull noundef align
8 dereferenceable(sizeof(LuceHost))` — the service table is a
`const LuceHost *` for the whole run — `%rt` is `nocapture nonnull`,
and `%out` is `writeonly nocapture nonnull dereferenceable(n)`.

**What `inaccessiblemem` may cover moved when inline access
arrived.**  It means, in LangRef's words, memory *not accessible by the
current module*, and until generated code walked the object table that
described the whole heap.  It no longer does: the module loads the
table's base out of `%rt`, compares a row's `generation` against the
handle's, and loads and stores array elements directly.  A false `inaccessiblemem` is not a
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
pair apart in the entry block, so `parse_i64(s) else 0` costs the parse
and a branch.

**docs/FAILURE.md proposed a sentinel for the heap case and it does not
work.**  The memo said a heap `T?` could be "the existing `i32` with the
null index".  Two things are wrong with that.  The small one is the
width: a handle became `{index, generation}` packed in an `i64` when
generational handles landed, so there is no `i32` any more.  The
disqualifying one is that the null index is already spoken for.  The
null handle is the *zero of an object-typed place* — a value that
is **present** and traps `null_object` when used — and a program can
put one inside a `T?` without a diagnostic:

```luce
func look(xs: list[i64]?) -> bool:
    return xs == none

func main():
    var raw: list[i64]          # the null handle
    print(str(look(raw)))       # interpreter: false — it is *there*
```

Absence on the interpreter is `Value.Tag.none`, a tag beside the
payload, so that program prints `false`.  A sentinel lowering would
print `true`, and the two engines would part company on the one program
that distinguishes them.  There is an agree test named for it.

Nor would the sentinel have paid. Numeric values, bool, str, and structs
have no spare value to encode absence in, so `{T, i1}` is forced for
six of the seven payloads; spending the seventh differently buys a word
that SROA was going to eliminate anyway, in exchange for the one
representation both engines can be checked against.

Where a `T?` has to become a `runtime.Value` — a struct field, an
argument crossing into `libluce_rt` — absence boxes as `Value.none`:
tag zero, no payload, no length, byte for byte what the interpreter
parks in the same slot.  **That is what makes reference counting cost
nothing.**  The runtime's retain/release walks switch on the tag and
fall through on `none`, so "holding `none` retains nothing" is already
true on both engines with no code written for it, and a present
`list[T]?` retains and releases exactly as the bare handle does.  It is the one place the box
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
`error("x: " + str(n))` hands over bytes a statement temporary is
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
`runtime/{value,heap,containers,text,operators,trace,exports}.zig`.  Luce's
semantics below the instruction level live here: the object heap,
reference counting for bindings, containers, temporaries and program
roots (docs/MEMORY.md), `list`/`map`/`array`/
`builder`, string storage and the string primitives,
`str`/`parse_i64`/`parse_f64`/`chr`/`ord`, checked arithmetic, and
the trap channel they all report through.

The constant materialization exports (`constants_begin`,
`constant_publish`, `constant_load`, `constants_finish`,
`constants_abort`, and `discard_loose`) are runtime services, not
host effects.  They install ordinary container rows under the program
owner and make every mutator's existing resolution seam the immutable
backstop.  Adding them changed no `LuceHost` field and therefore did
not move the published ABI.

It builds as a real `libluce_rt.a`, installs beside the binaries, and
`cc` links it into every artifact.  **The oracle calls it too** —
`interpreter/machine.zig` keeps only the dispatch loop, the frame
stack, the traceback, and host effects.  There is exactly one
implementation of every semantic, and the specs are what prove it.

The C surface (`runtime/exports.zig`, some 72 `luce_rt_*` entry
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
against the Zig struct, so the two cannot drift.  Its tag is one byte,
and the run after the fields that describe the text is where a string's
text lives when it fits; generated code only ever *writes* the other
form, and reads both.  How much fits, and where the run starts, are
`runtime.inline_capacity` and `runtime.inline_at` — stated there and
nowhere else, because a count repeated in prose is a count that goes
stale (docs/STRINGS.md).

## The published host ABI

`src/luce/codegen/abi.zig` is the contract and the only authority on
it; `abi.version` is the number a loader checks, and this page does not
repeat it — the copy that stood here had been wrong through six bumps.
A compiled artifact exports one symbol:

```c
int32_t luce_main(const LuceHost *host);   /* 0 ok, 1 trapped, 2 exhausted, 3 errored, 4 exited */
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
come through it: lists, maps, strings, reference counting, and the
conversions are `libluce_rt` calls, because they are the language rather than a
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

Two slots are outbound-only — the program tells the host something and
gets nothing back.  `finished` is the object leak census at the end of
a run that did not trap: memory is explicit in Luce, so what a program
did not free is part of what it did.  `exited` (ABI 10) is the number
a program chose to stop with, handed over at the `exit(status)` site
before the unwind.

Before 1.0, the table is versioned rather than source-compatible. Field order
*is* the layout, so any removal, reorder, meaning change, or signature change
updates every host and generated slot together and bumps `version`. A loader
refuses an older version; there is no adapter or migration path.

Version history, which is also the shape of the decisions: **2**
dropped `str_int` — a pure conversion belongs in the runtime, where it
is `luce_rt_str` — and added `finished`.  **3** added the remaining
host-table slots (files, command-line input, the terminal) and with them
the single `Answer` convention, which changed `print`'s return type and
so required the bump.  **4** made a trap a whole trap: `trap` carries the
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

**10** gave a run a fourth way to end: the program said so.  `Status`
gained `exited`, and one optional slot arrived at the end of the table
— `exited(status)`, called at the `exit(status)` site *before* the
unwind, so the host records the number while the program is still
leaving.  It fails closed like every other effect: a host without the
slot traps `host_unavailable` at the call, because a program that
means to stop with a number and a host that cannot carry one out is
not a success.  No field moved.

**11** let a program ask what machine it is on: `os_total_memory`,
`os_available_memory` and `os_cpu_count`, appended together at the end
of the table, each answering a number through an out-parameter under
the usual `Answer` convention.  Three at once and not one at a time,
because a version bump is a rebuild of every artifact there is and the
machine's facts are one subject — asking for them a release apart
would spend that three times over.  What is new is only what `no`
*means* on these slots — **this host cannot tell** — and that is the
same refusal a null slot gives, so the program traps
`host_unavailable` either way and no host has to invent a number.  No
field moved.

**12** made a file bytes reached through an open handle
(docs/BYTES.md).  Five slots appended in one run — `handle_open`,
`handle_read`, `handle_write`, `handle_flush`, `handle_close` —
carrying raw bytes with no opinion about encoding: a read fills a
buffer the caller owns and answers the count, a write takes a buffer
and a length, and zero read with a `yes` is the end of the file rather
than a refusal.  Named for the handle and not for the file, because
the same five serve a socket when `std.network` arrives.

Three things move with them, and they are one movement, which is why
they are one bump.  **UTF-8 validation left the host**: `file_read` is
open-read-close over the channel plus `libluce_rt`'s own check, so the
interpreter, a compiled artifact and every future host agree
byte-for-byte on what "not text" means — that sentence used to live in
`apps/host.zig`, where only loom could say it. At ABI 12, the replaced
whole-file callbacks became unused tombstones; ABI 24 removes those
pre-1.0 fields entirely. And **the channel is installed
rather than called through**: `luce_rt_files_install` hands the five
pointers to the runtime once at the start of a run, and the runtime is
what calls them.

That last one is the shape of the decision rather than a detail of it. ARC
closes a handle in the runtime's last-release walk, where no generated code is
standing to hand a table in. Installing the channel also puts both
engines on *literally the same five function pointers*, so what an
open answers, what a short read means and when a close happens are one
implementation rather than two that could disagree; the four handle
intrinsics lower to plain `luce_rt_*` calls, and the backend never
learns the handle's semantics at all.

`key_text` has no slot of its own: it answers what the last `key_read`
carried, which the runtime remembers, so it fails closed on
`key_read`'s slot.  End of input clears it, which is why the lowering
clears both out-parameters before the call: a host that answers `no`
may leave them untouched, and the payload of a key that never came is
`""` and not the one before it.

**13** appended the worker spawn and join slots, the whole machine
surface needed by Luce's worker values. **14** appended `shell_run`: one
host-shell command returns captured standard output and standard error,
with the exit status included in the transcript. A non-zero command exit
is data; only failure to start the shell is an I/O error.  **15**
appended `term_event_data`, the number-only query for the mouse
coordinates, button, modifiers and wheel value of the event `key_read`
just answered.

**16** appended two unrelated services in one bump, because a version
is a rebuild of every artifact there is and paying that twice in a week
buys nothing.  `dir_create` makes a directory **and every directory
leading to it**, and answers `yes` for one that was already there —
both halves of "there is a directory at this path when I return",
which is what keeps a caller out of the check-then-create race an
existence question is documented never to be a guard against.
`epoch_ms`
answers milliseconds since the Unix epoch, which `clock_ms` cannot: that
clock is monotonic with an unspecified origin, so only its differences
mean anything.  It takes the machine facts' shape — an out-parameter
and an `Answer` — rather than `clock_ms`'s bare `i64`, because a host
with no calendar has to be able to say so instead of inventing a date,
and the program then traps `host_unavailable` exactly as it would
against a null slot.

**17** appended `path_kind` and retired `file_exists` from use.  The
retirement is the point: a bool answered `false` both for a name
nothing holds and for a file under a directory nobody may open, and a
program could not tell the two apart.  `path_kind` widens the
*payload* rather than the `Answer` — `yes` fills a kind code, 0
nothing, 1 file, 2 directory, 3 other, and `no` is the world refusing
to say, which the program meets as `io_failed`.  Inventing a fourth
`Answer` for "there is nothing there" would have changed what `Answer`
means at every other slot, and absence is not a refusal.  Links are
followed, so the kind describes the same file the next call touches.
The lowering is the machine facts' shape with a path in front of it:
zero the box, call the slot, raise on `no`, load the code — and the
code gets its names in `std.files`, exactly as the byte channel's mode
does.

Two shapes the version-8 slots settled, both of which stayed inside
the conventions already there rather than inventing new ones:

- **A directory listing travels as bytes.**  Every service that hands
  text back hands back a pointer and a length, and `dir_list` answers
  the names **NUL-separated in one buffer**; `luce_rt_names_list`
  splits it into the `list[str]` the program asked for.  A second
  convention — a vector of pointers, a callback per name — would be a
  second thing every host author has to get right, and NUL is the one
  byte a file name may not contain, so the joining loses nothing.
- **A service that may have nothing to say clears its out-parameters
  first.**  `read_line` and `env` answer a `str?`, and their `no`
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
integers, floats, strings, structs, function values, all four container
kinds, handle/task resources and workers, `T?`, `T!`, reference counting, the math
builtins, and every host service.  The two things that did not — `Bytes`
and the evaluator ports — were cut rather than grown (docs/ENGINE.md
steps 1 and 2), because nothing constructed a `Bytes` and nothing
reached an evaluator.

`grep 'self.fail("' src/luce/codegen/lower.zig` is still the
authority, and what it finds now is entirely refusals of IR that could
only arrive damaged: a block without a terminator, arithmetic on a
type that has none, an entry function with more than one parameter.  A
`.lc` is trusted like an executable, so those are how a forged one
reports itself instead of being `unreachable`.

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

One run, all nine rows: a table is one measurement or it is not a
table.  This is the one number — where a document quotes a benchmark
row it quotes the `compute` column here, and says which column it is.

| benchmark | C        | luce     | luce/C | compute |
|-----------|----------|----------|--------|---------|
| loops     |  80.1 ms |  90.8 ms |  1.13x |   1.05x |
| math      | 137.7 ms | 115.4 ms |  0.84x |   0.78x |
| strings   |  19.7 ms |  75.4 ms |  3.82x |   3.87x |
| arrays    |  43.3 ms |  53.2 ms |  1.23x |   1.07x |
| arrays32  |   7.8 ms |  48.7 ms |  6.26x |   7.77x |
| matmul    |  10.5 ms |  17.6 ms |  1.68x |   1.02x |
| matmul32  |   6.5 ms |  13.4 ms |  2.05x |   0.99x |
| stats     |  32.2 ms |  49.0 ms |  1.52x |   1.34x |
| lists     |   8.0 ms |  23.3 ms |  2.93x |   2.61x |
| floor     |   2.8 ms |   9.7 ms |      - |       - |

Two rows carry a story worth keeping.  **`stats` (1.34x compute) is
the price of the parked `llvm.minimumnum` vectorization** ("The
extrema, and a vectorization that is parked" above): the extremum
reduction is scalar compare/select until the intrinsic's x86-64
lowering can be trusted, and the two extremum passes are a third of
the row's work.  **`arrays32` (7.77x) is the price of checked integer
arithmetic in a reduction** — the section below shows it is not a
32-bit problem.

The link line matters to these numbers, and the rule is one mechanism
on every OS.  `libluce_rt`'s bundled compiler-rt object defines the C
library's public names — `memcpy`, `memset`, the libm surface — and if
it wins the `cc`-driven static link over the platform's optimized ones
it costs tens of percent on the allocation-bound rows.  So bundling
stays only where the link genuinely needs Zig's compiler-ABI symbols
(`__zig_probe_stack`, the half-float conversions — Linux, where the
unbundled link is simply broken), and `tools/localize_rt.zig` confines
the bundled object to the compiler's namespace, so `memcpy` stays an
undefined reference that binds to the real libc at load.  macOS needs
no bundle and carries none.

`strings` and `lists` are allocation-bound rather than
code-generation-bound.  Five rows — `loops`, `math`, `arrays`,
`matmul`, and `matmul32` — are within 7% of C or ahead after startup is
removed.  `math` is ahead because Luce's transcendental calls land in
the same libm C's do while the surrounding loop vectorizes; `stats`
and `arrays32` carry the separately measured costs described here.

### The Phase 0 resource baseline

The runtime column above is the best-of-five measurement.  The other
columns below are one warm macOS ARM64 run of `/usr/bin/time -l` around
the release compiler or runner; peak memory is maximum resident set
size.  `loops` is value-heavy, while `lists` allocates and grows the
reference container that ARC must reclaim.  These are comparison
anchors for later type, weak-reference, class, and closure phases, not
cross-machine performance claims.

| program | compile | artifact | runtime | compile peak RSS | runtime peak RSS |
|---------|---------|----------|---------|------------------|------------------|
| `loops` | 0.05 s  | 870,032 B | 90.8 ms | 41,844,736 B | 12,255,232 B |
| `lists` | 0.10 s  | 886,544 B | 23.3 ms | 48,103,424 B | 28,016,640 B |

### The 32-bit rows

**`matmul32` is the good news and it is unremarkable, which is the
point.**  0.99x compute against 1.02x for the `f64` twin: the
binary32 inner loop vectorizes on both sides, four lanes where the
64-bit one got two, and Luce keeps pace.

**`arrays32` is 7.77x, and it is not a 32-bit problem.**  The
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
sits at 1.07x.  `loops` and `stats` are checked integer loops too, but
neither is a reduction C can vectorize.  It took an integer reduction
to separate the two, and that is what `arrays32` is.

**Nothing here is a regression and nothing here is fixed by widening
back.**  It is a standing cost of the safety guarantee, now measured
rather than assumed, and the options if it is ever worth spending on
are the ordinary ones: prove the bound and drop the check, or offer a
reduction that is allowed to reassociate.  Neither is in this step,
and both are language decisions rather than code-generation ones.

### `bench/lists`, and what packed storage buys

`bench/lists.luc` is nothing
but `list`: three million `append`s into a `list[u8]` that starts
empty, a sequential read, a strided read at a prime stride that visits
every element in an order no prefetcher follows, an in-place
transform, a 256-counter histogram in a `list[i64]` indexed by a
byte, and then the same four shapes again at eight bytes an element.
That is the shape a decoder runs — `std.zip` and any inflate are a
buffer that grows by append, a table indexed by a byte, and a pass
that rewrites in place.  `bench/lists.c` is the same algorithm over
`realloc`'d buffers, down to Luce's own growth schedule (eight
elements, then 1.5x plus one) so that neither side is copying its
buffer a different number of times than the other; both print the same
eight numbers and `bench/run.sh` refuses to time them otherwise.

**Packed storage — a `list[u8]` at one byte an element, a
`list[i64]` at eight, where every element was once a 24-byte boxed
slot — is worth about 22% of this program's compute and 5.7x of its
memory** (measured by hand against the commit before `list[T]` gave up
the boxed cell, since the benchmark does not exist at that ref for
`bench/compare.sh` to build).  Peak RSS falls from 113 MB to 20 MB.

Packed storage alone did not make a `list` fast, though: element
access was still an out-of-line `luce_rt_*` call over boxed `Value`s
for `index_get`, `index_set` and `append_value`.  Making each cell one
byte did not remove the call.

### What removing the call bought

**2.61x compute, where element access through boxed `Value` calls was
29.10x.** The three changes are read in "Inline access": a `list[T]`'s storage
kind became a fact of `T` rather than of whoever built the object,
element access joined the inline path under the invalidation rule the
tree already enforced, and `append` became a store and a count bump
with the runtime called only to grow.

Timing the phases inside the program, against the same phases of the C
twin on the same host:

| phase                                | luce  | C     |
|--------------------------------------|-------|-------|
| 1. three million `append`s           |  6 ms |  1 ms |
| 2. sequential read                   |  1 ms |  1 ms |
| 3. strided read at a prime stride    |  3 ms |  2 ms |
| 4. in-place transform                |  0 ms |  0 ms |
| 5. 256-counter histogram             |  1 ms |  1 ms |
| 6. the same shapes at eight bytes    |  3 ms |  1 ms |
| total (compute)                      | 14 ms |  6 ms |

**Every reading phase is at C's speed and the whole of the remaining
gap is `append`.**  Phases 2 through 5 — a sequential read, a walk no
prefetcher follows, a rewrite in place, and three list operations an
element — are the numbers `arrays` has always had, which is what the
same row walk over the same storage should give.  Phases 1 and 6 are
the ones with appends in them.

**Why an append is still four times C's.**  C's `push` keeps `n` and
`cap` in registers; Luce's has to keep them in the row, because the
row is what every other name for the list reads.  So each append loads
the count, loads the capacity, stores the count — and the store feeds
the next iteration's load, a forwarding dependency C does not have.
Promoting the count to a register across the loop is exactly what LLVM
would do, and it is blocked by the growth arm: `luce_rt_append` may
write anything, and it is inside the loop.  That is not a missing
optimization so much as the price of a list whose length one name
cannot cache from another, and closing it means something like
unswitching the loop on "there is room for the rest", which is a real
piece of work and not this one.

**What is deliberately not inline.**  An `append` of a `str`, a
struct or an object still calls the runtime, because such an element
has to be *adopted* and the release walk lives in one place.  No row
in the suite measures that (`strings` builds text in a `builder`, not a
list), so there is no number here to quote and none is invented.

## Building

libLLVM is a hard build dependency of **the `luce` compiler**, because
the one code generator calls it in process.  `build.zig` finds it by
asking `llvm-config` for its include directory, library directory,
libraries, system libraries, and C++ runtime, and it looks in three
places in this order: **the vendored prefix
`.llvm/install/bin/llvm-config` first** — what `./vendor-llvm.sh`
builds, the version this compiler is tested against, statically linked
so `luce` depends on no LLVM the machine happens to have — then
`PATH`, then the usual Homebrew and distribution prefixes.  Point the
build elsewhere with, which wins over all three:

```sh
zig build -Dllvm-config=/path/to/llvm-config
```

The public Linux archives make that static property part of their release
contract rather than depending on how a maintainer's workstation is set up.
`tools/linux-release/` builds both architectures on the glibc 2.28 baseline,
using immutable container bases, the checked Zig 0.16.0 download, and this
same pinned LLVM source. Its final dependency audit refuses a `luce` that
still names libLLVM, libstdc++, Z3, XML, zstd, libedit, or an unresolved
library. `www/luce/install-smoke.sh` then builds and runs real programs in a
container with no LLVM installation.

`loom` does not link it and must not start doing so; the dependency is
confined to the `emit` module (above), and `otool -L build/loom` is
how that stays true.

**`cc` is a dependency of building at all**, not only of testing.
`build.zig` compiles the ten bundled programs and the nine benchmarks
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
links the runtime, so one is ~774 KB whatever the program says and the
ten bundled programs total 7.9 MB.  A dylib beside the binaries would
collapse that, and would trade a self-contained file that runs
anywhere the machine matches for an rpath and a version-matched
install.  That is a change to what an artifact *is*, and it is not
made here.

The interpreter's dispatch loop does not go anywhere.  It is the
differential oracle the specs run every program against, it ships in
nothing, and its interpreted arms are a fraction of a second across the
whole suite (docs/ENGINE.md).

One smaller thing this path leaves open on purpose:

- **Nothing sweeps `.lc` files.**  They sit beside their programs and
  are deleted with them; the `TMPDIR` copies are the session's to
  clear.  A cache that grows without bound would need a policy, and a
  content-addressed file next to the thing it was addressed from does
  not.
