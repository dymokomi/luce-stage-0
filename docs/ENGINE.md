# One engine — retiring the interpreter

> **The rule.** Luce ships **one engine**: source goes through LLVM to
> machine code, and the thing loom loads *is* machine code. The
> interpreter stops being an engine — no fallback, no `LOOM_ENGINE`, no
> second dispatch loop in either binary — and survives only as the
> **differential oracle in the test suite**, which ships in nothing and
> exists to disagree. `libluce_rt` is untouched by all of this: it was
> already the one implementation of every semantic, and it stays.

This is the audit, not the retirement. Nothing is deleted here. What
follows is what the interpreter actually does today, measured; what
each of those jobs costs to give up; the one recommendation on the
oracle question; and the ordered plan.

Everything below was measured on this tree at `df5d48f`, Apple M4 Max,
`./build.sh` (ReleaseSafe) unless a number says otherwise. `zig build
test` is green: **849/849 in 71.1 s**.

> **Steps 1, 2, 3 and 8 are done.** `.lc` `format_version` is 17,
> `abi.version` is unchanged at 8 (nothing in the host ABI ever named a
> port or a `Bytes`), the lowering is total, and `zig build test` is
> **838/838 in ~4 min** (3 m 59 s – 4 m 06 s over two runs). The executable specification is its own
> module and every test in it runs on both engines; the interpreter's
> own suite is **2** tests (36 before, 39 before that). Each step below
> carries a note on what it cost in contact with the code.

---

## What is actually there

| | lines |
|---|---|
| `interpreter.zig` + `interpreter/machine.zig` | **1,074** |
| `interpreter/test.zig` | 1,486 |
| `backend.zig` (the boundary, almost all of it the interpreter's) | 257 |
| `07_optimize/values.zig` + `flow.zig` (interpreter-only, by their own headers) | 498 |
| `host.zig`'s `backend.Host` adapter (`host()` + 23 Zig-signature services) | ~32 + services |
| whole `src/` tree | 53,285 |

So the engine itself is **1,074 lines, 2.0% of the tree** — because
`libluce_rt` already holds every semantic and the interpreter kept only
the dispatch loop, the frame stack, the traceback, and host effects.
The "cost of keeping it" is a number, and it is small.

The cost of *depending* on it is a different number, and it is large:

| | tests | program runs |
|---|---|---|
| execute a Luce program on the interpreter **and nowhere else** | **282** | **321** |
| execute on **both** engines (`agree`) | 61 | 83 |
| execute compiled only | 21 | — |

The 282 are `specs/behavior_spec.zig` (127), `specs/ownership_spec.zig`
(78), `specs/std_spec.zig` (19), `interpreter/test.zig` (37),
`specs/errors_spec.zig` (12 — the rest are compile-time diagnostics),
`compile/test.zig` (6), `06_mir/module.zig` (2), `07_optimize/test.zig`
(1). *(Correction from step 8: `errors_spec` executes **nothing** — it
is compile-time diagnostics end to end, and always was.)*

**Read that table again.** The executable specification of the
language — behaviour, ownership S1–S43, the standard library — proves
the engine that is about to be retired, and the engine that actually
runs has 61 comparison tests and 21 of its own. That asymmetry is the
single most important finding in this audit, and it is upside down.
Whatever happens to the interpreter, **the specs have to move onto the
compiled path**, and that is true on every branch of the decision.

---

## Hat 1 — the differential oracle

`08_llvm/test.zig`'s `agree` compiles one source, runs it on the
interpreter through `backend.evaluateHosted` against a `Reference`
host, runs it compiled through `dlopen` against a `Capture` host built
from the *same* `World`, and demands the same printed bytes, the same
trap code, the same trap message, **the same call trace frame for
frame**, and the same leak census. 61 tests, 83 comparisons.

It has caught real bugs, and the tests are named after them:

- `"the null object put in a T? is present, because absence is not a
  handle"` — the semantic error. `docs/FAILURE.md` proposed lowering a
  heap `T?` to the null handle; the null handle is the *zero of an
  object-typed place* (S40), a value that is **present**, so
  `xs == none` answers `false` on the interpreter and would have
  answered `true` compiled. One program in the language distinguishes
  the two designs and the oracle is the thing that runs it.
- `"an error path releases the objects and the String storage it
  owns"`, `"a caught error leaves the value it never produced
  releasable"`, `"a fallible call's result is carried, not taken"` —
  the use-after-free in the errors lowering. `docs/STRINGS.md`:
  carrying a fallible call's result in a *borrowing* slot marked short
  text as outside text, and the statement's release freed a pointer
  into the frame.
- `"a store that traps still owns what it was handed"` — the double
  free.

**All three were silent-agreement bugs.** The compiled arm produced
plausible output. What caught them was a second implementation
answering differently about a leak census, a trap's position, and one
boolean. That is not a property a golden-output file has, because
nobody writes a leak census by hand.

### What the oracle costs to keep

Measured. An interpreted run of a spec-sized program is *below the
resolution of process startup*: `LOOM_ENGINE=interpreter loom run
sort.lc` is **2.0 ms** against loom's own **2.2 ms** floor. Inside
`agree` there is no fork at all. The compiled arm of one agree test
costs **205 ms** (17.0 s / 83), because it compiles, links and
`dlopen`s. **The reference arm is under 0.5% of the agree suite.**

### The alternatives, priced

- **Golden-output tests.** Cheap, and they would have caught none of
  the three. The leak census and the trace are the discriminating
  facts, and a golden file only has them if a human transcribed them
  from the semantics — which is what the interpreter does
  automatically, for every program, on every run.
- **Property fuzzing against `libluce_rt`'s own assertions.**
  `libluce_rt` was **correct** in all three cases. The lowering
  marshalled into it wrongly — a borrowing slot where an owning one was
  needed, a sentinel where a tag was needed. There is nothing for the
  runtime to assert about a value the lowering never handed it.
- **Nothing, with eyes open.** Honest, and wrong at this moment in the
  project: `08_llvm/lower.zig` is 4,702 lines and changed this week.

### The recommendation, and it is one answer

> **Keep the interpreter as a test-only differential oracle. Retire it
> as an engine.**

**Ratified 2026-08-03.** The owner's terms: keep it *exactly the way
the other languages do* — Rust's Miri (an in-tree MIR interpreter that
ships as a dev tool and never as an engine), Zig's one behavior suite
run against every backend, Go's `toolstash -cmp`, Wasm's reference
interpreter — and **bring the engines into full parity**, because the
coverage between them is uneven in exactly the wrong direction: 282
spec tests prove only the oracle, 61 prove both, 21 prove only the
engine that runs. Every spec becomes a two-engine comparison; nothing
proves the interpreter alone. Size and compile time are declared
inconsequential for now — future optimization, never a reason to keep
a test off the compiled path.

The deciding argument is not sentiment, it is that **deleting it does
not save the test time, and keeping it does not cost the test time.**

The specs have to move onto the compiled path either way (above). That
move costs 321 runs × 205 ms ≈ **+66 s**, taking `zig build test` from
71 s to roughly 137 s. You pay that whether the interpreter lives or
dies. If it dies, you pay it and get one implementation's opinion. If
it lives, you pay it plus ~0.3 s of interpreted arms and get two.
**Keeping it is strictly dominant**: same bill, free second opinion,
1,074 lines.

What it costs, said plainly: **1,074 lines that must keep compiling,
and the risk that an oracle nobody ships rots into disagreement.**

### The discipline that keeps it honest

1. **It ships in nothing.** `loom` and `luce` must not reach
   `interpreter/`. The check is structural — a build-graph assertion,
   the way `otool -L build/loom` polices libLLVM today.
2. **It has no product role.** `Engine`, `Policy.engine`,
   `LOOM_ENGINE` and `runInterpreted` are deleted. The only caller of
   `interpreter.run` is a test harness.
3. **It may never acquire a semantic.** Today's rule ("never add a
   semantic to one side of that line") becomes an invariant with a
   place to stand: `machine.zig` calls `runtime.zig` and nothing else
   goes in it.
4. **Rot is prevented by making every spec a comparison.** An oracle
   that is only consulted by 61 curated tests can drift. An oracle that
   is the second arm of all 282 spec tests cannot drift silently —
   every one of them is a disagreement detector. Step 8 of the plan is
   what makes this true, and it is the same step the retirement needed
   anyway.

---

## Hat 2 — the fallback

`loom run` prefers native and falls back silently
(`runner.artifactFor`). The compiled path needs four things: the
`luce` binary, a lowering for everything the program says, a C
toolchain, and somewhere to write.

**The direction dissolves this question rather than answering it.**

Today a `.lc` is *portable IR*, which is to say it is not executable,
which is why there has to be something to fall back to. Make the `.lc`
the native artifact and there is nothing to fall back from: `loom run
FILE.lc` is one `dlopen`, one symbol lookup, one call — **2.5 ms
measured** — and it needs no compiler, no C toolchain, no LLVM and no
lowering at all.

This *strengthens* the no-compiler machine rather than weakening it.
Today a `.lc` on a machine with no `luce` runs on the interpreter at
30–60× the compiled speed (`bench/loops`: 7,020 ms against 84 ms).
Tomorrow it runs at full speed with nothing installed.

What remains, and it is the honest cost:

| on a machine with `loom` but no `luce` | today | after |
|---|---|---|
| `loom run p.lc` (shipped program) | interpreted, 30–60× slow | **full speed** |
| `loom luce p.luc` (source) | interpreted | fails: compiler missing |
| `loom edit FILE` | interpreted | fails: compiler missing |

The last two become the failure a C project has without a C compiler,
and they should say so in the sentence `native.findCompiler` already
writes: *"the `luce` compiler is not beside /usr/local/bin and not on
PATH"*. That is a better outcome than a silent 40× slowdown, because
it is a fact the person can act on.

The two lowering gaps that make the fallback load-bearing today are
`Bytes` and the evaluator ports — 11 of the 34 `self.fail(` sites in
`lower.zig`; the other 23 refuse IR that could only arrive damaged.
`Bytes` is **unconstructible** (`docs/MISSING.md` item 8): `var b:
Bytes` compiles, nothing produces one, and a grep across
`src/luce/std/`, `programs/`, `bench/` and the site's 173 samples finds
zero uses. The evaluator ports are v1 machinery `docs/V2.md` already
defers. Cutting both makes stage 10's lowering **total**, and that is
step 1 and 2 of the plan.

---

## Hat 3 — `luce check` and iteration speed

The measurements, best of 5–7, `TMPDIR` isolated, artifacts deleted
where a run is marked cold:

**Front end** (all of these link libLLVM and use none of it):

| | ms |
|---|---|
| `luce check hello.luc` / `life.luc` / `editor.luc` | 7.9 / 7.4 / 8.4 |
| `luce ir hello.luc` | 7.5 |
| `luce build → .lc` (hello / life / editor) | 7.4 / 7.7 / 8.7 |
| loom, no arguments (floor) | 2.2 |

`luce check` is 8 ms and about 5.7 ms of that is dyld binding a 164 MB
`libLLVM.dylib` for nothing. `docs/CODEGEN.md` already names the fix —
another binary, the way loom got one — and this audit does not change
that verdict: 8 ms is fine, and the fix is available if
check-on-save ever matters.

**Running a source file** — the loop a person is actually in:

| program | interpreter | native cold | native warm |
|---|---|---|---|
| hello | 4.8 ms | 149.6 ms | 4.6 ms |
| sort | 5.3 ms | 174.5 ms | 5.4 ms |
| stats | 4.7 ms | 193.8 ms | 5.3 ms |
| wordcount | 4.6 ms | 191.4 ms | 5.4 ms |
| editor (`--emit=library`) | — | 199.3 ms | — |

**Warm is a tie.** Cold is 30–42× the interpreter, and cold is what
every real edit costs, because the artifact is keyed on the serialized
module and a code change changes it.

Where the cold 150–210 ms goes (`sort.luc`, measured one term at a
time):

| | ms |
|---|---|
| front end to `.lc` | 7.8 |
| + LLVM at `-O3` to a relocatable object | 26.2 |
| + `cc` link to a loadable artifact | 51.8 |
| + **first `dlopen` of the freshly written dylib** | **89.4** |
| total | **154.6** |
| second `dlopen` of the same file | 3.5 |

**The largest single term is not compilation.** 89 ms of it is macOS
validating a binary it has never seen; loading the same file again is
3.5 ms. So the iteration-speed complaint is 58% an OS security check
and 42% a compiler, and the half that looks like a compiler problem is
not the half to attack first.

Two properties soften the loop, both measured:

- **A comment-only edit does not rebuild.** The key is the serialized
  module, so appending `# a trailing comment` leaves the debug `.lc`
  byte-identical and the run stays warm at 4.7 ms. A *leading* comment
  shifts every debug origin and does rebuild (166.6 ms). Under
  `--release`, where origins are stripped, all three encode to the same
  bytes.
- **A shipped program costs nothing.** `luce build --emit=exe` gives a
  file the shell runs in **2.1–2.3 ms** that links only
  `libSystem.B.dylib`.

**The verdict, stated honestly: iteration speed is the one thing
genuinely lost.** 145 ms per save is under the threshold where a wait
reads as a pause rather than a lag, and it is 30× what the interpreter
charged. It is a real regression for the person editing `editor.luc`,
and it is not a reason to keep two engines — it is a reason to look at
the 89 ms.

---

## Hat 4 — the step budget and `backend.zig`'s boundary

**Nothing real depends on the step budget.** `grep '\.steps = '` finds
16 sites; fifteen are tests and the sixteenth is
`loom/runner.zig:80`, which sets `std.math.maxInt(u64)`. The trap code
`step_budget_exhausted` is raised at exactly one place in
`machine.zig` and asserted by exactly one test. It was the evaluator
ports' deadline analog, and the ports are dying.

**Call depth is different and stays.** It is a language promise —
runaway recursion traps rather than overflowing the machine's stack —
and both paths already keep it from the same number:
`host.call_depth` reaches the interpreter as `Budget.call_depth` and a
compiled artifact through the ABI's `call_depth` slot. Compiled code
counts it in `%depth`, an IR-level subtract that LLVM hoists to the top
of each function and that measured `-0.75%` to `+0.63%` — noise.

**What is left of `backend.zig` with one engine: almost nothing.** Two
of its exports are already aliases of the runtime's (`Memory =
runtime.Memory`, `RuntimeValue = runtime.Value`). `evaluate` /
`evaluateHosted` are a one-line forward to `interpreter.run`. `Host`,
`Terminal`, `KeyEvent`, `Budget`, `Result`, `Trap`, `Raised`,
`InputValue`, `FileRead` are the interpreter's own shapes — the
compiled path has `abi.Host`, `abi.Status` and `runtime/trace.zig`'s
report instead, and `host.zig` builds both tables from one set of
services. So the boundary goes where the oracle goes: the two aliases
move up to `luce.zig`, and the rest becomes the oracle's own header.

The file's `//!` still says *"The first engine behind the boundary is
the deterministic Luce IR interpreter"* and *"A native code generator
slots in behind these same types."* It did not: it slotted in beside
them, with its own published ABI, which is the better outcome and the
reason the boundary can now go.

---

## Hat 5 — the site

`site/src/verify.zig` runs every sample twice — `LOOM_ENGINE=native`
so a silent fallback is a failure, then `LOOM_ENGINE=interpreter` —
and fails the build if the two disagree. Measured: **48 pages, 173
samples (121 run, 22 trap, 5 raise, 23 refused, 2 shell), 25.0 s.**
148 of them execute on both engines.

The second arm costs 148 × ~2 ms ≈ **0.3 s, 1.2% of the site build**.
That is the cheapest differential coverage in the tree, over a corpus
far more varied than the 61 agree tests.

But it dies with `LOOM_ENGINE`, because the site asks *loom* for the
reference engine and loom will not have one. What survives is the
property that actually keeps the site honest: every sample is compiled
and run by the freshly built toolchain and the page's claimed output is
compared byte for byte. That is unchanged, and it is one engine's job.

**What is lost is real and should be written down: 148 varied programs
stop being differentially checked.** The recovery, if it is wanted, is
to let the agree harness read the site's sample corpus rather than
carry its own — the samples are already whole `main.luc` programs with
declared outcomes. That is not part of the retirement; it is the thing
to do with the budget the retirement frees.

---

## Hat 6 — format and portability

Today `.lc` is a direct binary serialization of verified MIR
(`format_version` 16) and `.lcn` is the tagged native artifact beside
it. The direction makes `.lc` the artifact. Six consequences, each
with its evidence.

### 1. Size, and the decision it forces

| program | `.lc` | `.lc --release` | `.lcn` | `--emit=exe` |
|---|---|---|---|---|
| hello | 690 | 481 | 682,936 | 1,121,848 |
| sort | 3,198 | 2,231 | 699,448 | 1,121,848 |
| life | 9,100 | 6,244 | 699,448 | 1,121,880 |
| editor | 54,291 | 37,354 | 732,984 | 1,171,912 |

The nine bundled programs go from **116 KB to 6.3 MB — 54×** — and an
artifact is ~683 KB whatever the program says, because `libluce_rt.a`
(3.3 MB on disk) is statically linked into every one of them.

**A shared `libluce_rt` is the answer, and it has to be decided with
the format change rather than after it**, because it changes what an
artifact *is*: a dylib beside the binaries, an rpath, and a
version-matched install, against a self-contained file that runs
anywhere the machine matches. The tag already has the machinery to
police the version (`abi.version`, `abi.generator`), and a standalone
`--emit=exe` can keep linking statically. This memo names the decision;
it does not take it.

### 2. Portability, and whether cross-compilation is the answer

A native `.lc` is not portable, and the tag says so by name rather than
crashing: `abi.machine` is `aarch64-macos-none` built from `builtin`,
`abi.generator` is a build-time hash of the backend, the runtime, the
toolchain and libLLVM, and `check` refuses with four distinguishable
sentences — not an artifact, wrong ABI, wrong machine, wrong generator,
stale program.

Cross-compilation is **half-built**. `08_llvm/emit.zig` registers
AArch64, X86 *and* WebAssembly target infos and takes a triple as a
parameter — but `src/apps/luce/object.zig` hard-codes
`emit.hostTriple()` and the CLI has no `--target`. What is genuinely
missing is not the code generator: it is **the link**. `cc` links for
the host, and `libluce_rt.a` is built for the host, so cross-compiling
means one `libluce_rt` per target and a linker willing to take it.
`zig cc` is the obvious answer and Zig is already a build dependency.
Name it as the plan for "ship to a different machine"; do not promise a
date.

### 3. The `luce build` CLI

`--emit=library` and the default collapse into one another:

```sh
luce build FILE.luc                 # FILE.lc   — loom loads it
luce build FILE.luc --emit=exe      # FILE      — a shell runs it
luce build FILE.luc --emit=object   # FILE.o    — you link it
```

What disappears is *serializing MIR as a deliverable*, not the format.

### 4. Serialized MIR survives, as an internal seam

Three loads it carries that nothing else does:

1. **It is the artifact key.** `abi.sourceHash` hashes the serialized
   module, and re-encoding a decoded module is byte-identical by
   construction, so the hash matches without a second compile. Delete
   the encoder and content-addressing has to be reinvented.
2. **It is why loom carries no code generator.** loom hands `luce` the
   module it is already holding rather than the source, so the artifact
   is keyed to the exact program about to run. That split is worth 5.7
   ms of dyld on every single loom invocation — loom's floor went 8.8
   ms → 3.1 ms — and it is what lets a machine that only runs Luce
   programs carry no LLVM. Verified here: `otool -L build/loom` names
   only `libSystem.B.dylib`; `build/luce` names `libLLVM.dylib`.
3. **It separates the front end from the back end.** `luce build
   FILE.lc` is a real capability, and `luce ir` needs the same
   structure.

So: **the format stays, the file extension leaves.** Serialized MIR
becomes an internal transfer form. Whether it keeps a user-visible name
for front-end/back-end runs is a small decision to take in step 4;
`format_version`'s discipline (bump on any instruction-set, intrinsic
or trap-code change; no migration) is unaffected either way.

### 5. `luce ir` is unaffected

It prints MIR from source through `06_mir/print.zig`. It never read a
`.lc` and does not start.

### 6. `cc` becomes a dependency of installing

`build.zig` compiles nine bundled programs and six benchmarks with the
freshly built `luce`; under a native `.lc` that becomes
`--emit=library`, and linking moves from *testing* to *installing*.
`docs/CODEGEN.md` declined exactly this on purpose ("that would make
`cc` a dependency of installing, not only of testing"). The direction
reverses that decision, and it should be reversed knowingly.

---

## Hat 7 — everything else the sweep found

- **`loom edit` already runs compiled.** `shell.edit` goes through
  `runner.runSource` with the ordinary policy; the embedded editor has
  no path, so its artifact is cached in `TMPDIR` under its hash. It
  costs 199 ms once and 4 ms after. **Nothing about the terminal path
  assumes the interpreter**: `host.zig` builds `backend.Host` and
  `abi.Host` from one set of services, and `printTrap` takes either
  engine's frame shape by structural match. Retiring the interpreter
  costs the editor a compiler dependency and nothing else.
- **An entire optimizer pass exists for the interpreter, and its own
  header says to delete it.** `07_optimize/values.zig` (246 lines):
  *"This pass exists for the interpreter only… If the interpreter ever
  stops being a shipping engine, turn `Passes.values` off and delete
  this file; nothing else depends on it."* `07_optimize/flow.zig` (252
  lines) says the same in its own words, and the barrel names both.
  Measured: they buy the compiled path **-2.5% LLVM compile time and
  0% runtime**, because `default<O3>` already finds everything they
  find. That is 498 lines the retirement collects for free.
- **The step budget's only production setting is "unlimited"** (Hat 4).
- **`docs/MODES.md:103` says `format_version` 15.** It is 16
  (`06_mir/module.zig:23`). A doc defect found in passing.
- **The prose is the largest single body of work.** A full sweep of
  README, CLAUDE.md, AGENTS.md, `docs/*.md`, `site/content/**/*.md` and
  the `//!` headers finds **232 sites across 44 files** that state
  there are two engines, name the interpreter as the reference,
  describe the fallback, or call a `.lc` portable IR (209 counting per
  line rather than per clause). Densest: `docs/CODEGEN.md` (33),
  `docs/MISSING.md` (16), `CLAUDE.md` (15),
  `site/content/guide/toolchain.md` (14). Four whole sections become
  obsolete rather than edited: CODEGEN.md's "Which engine runs a
  `.lc`", PIPELINE.md's "Where the compiled path diverges",
  toolchain.md's "The two engines", performance.md's L47–49. Two `//!`
  headers disappear with their files.

---

## What stays forever

**`libluce_rt` is untouched — confirmed, not assumed.**
`runtime.zig` + `runtime/{value,heap,containers,text,operators,exports,
trace}.zig` is 3,821 lines of implementation plus 996 of its own tests,
and its 30 tests call it **directly** — not through either engine.
Both arms call it; removing one arm changes nothing about it. The rule
survives verbatim: *there is exactly one implementation of every
semantic.*

Also permanent, and not in play here: **no ARC, no reference counting,
no GC, at any layer.** Nothing in this plan proposes reclaiming memory
for any reason but a scope ending.

Staying for their own reasons: `06_mir/module.zig`'s encode/decode (the
artifact key), `luce ir`, `07_optimize/{prune,ownership,dead,effects,
registers}.zig`, the `%depth` call-depth check, `abi.zig` and its
append-only discipline.

---

## The plan

Ordered, each step independently shippable, each with what it deletes,
what proves it safe, and what it forecloses.

### Now — this week, in any order, no prerequisites

**1. Cut `Bytes`. — DONE.**
*Deletes:* the type from `support/types.zig`, its arms in
`04_semantics/builder.zig`, `06_mir/defs.zig` and `machine.zig`, and 8
of the 34 `self.fail(` sites in `lower.zig`. Bumps `format_version`.
*Proves it safe:* it is unconstructible — `var b: Bytes` compiles and
nothing produces or consumes one (`docs/MISSING.md` item 8) — and a
grep across `src/luce/std/`, `programs/`, `bench/` and the site's 173
samples finds zero uses. The suite and the site build are the check.
*Forecloses:* nothing. A real `Bytes` would be designed fresh, and
`docs/MISSING.md` already says "cut it or grow it".
*What it took, in contact with the code:* the `Value` tag went too, so
`strukt`/`object` renumbered (nothing hard-codes a tag number — every
site is `@intFromEnum`), and `const_data`'s `data_type` field went with
it: the field existed only to tell String from Bytes, so the
instruction is now `const_string: u32` and one more `fail` site went
with the field. `Bytes` also left `reserved_names`.

**2. Cut the evaluator ports. — DONE.**
*Deletes:* `input_load`, `output_store`, `types.Port`, `PortSchema`,
`PortType`, `EntryMode.evaluator`, `backend.InputValue`, the `outputs`
slice, `Result.unavailable`, and 3 more `fail` sites. Bumps
`format_version`.
*Proves it safe:* no bundled program, benchmark or site sample uses
evaluator mode; `entry_mode = .script` is the only mode anything
reaches. `docs/V2.md` defers Fabric by design.
*Forecloses:* the Fabric's eventual `evaluate()` would have to
re-derive a schema. That is the right trade — it is deferred
machinery holding a live path hostage.
*After 1 and 2, stage 10's lowering is total*: `grep 'self.fail("'
lower.zig` leaves only refusals for IR that could only arrive damaged.
**Confirmed: 34 sites became 23, and all 23 are invariant refusals.**
*What it took, in contact with the code:* more than the memo listed.
`compile()`/`compileProject()`/`analyze()`/`mir.build.build()` all lost
their `schema` parameter; `backend.evaluate` lost `inputs` and
`outputs`; `Program.inputs`/`outputs`/`reads` and the `Analyzer.reads`
set went; and `EntryMode` went entirely rather than becoming a
one-variant enum, so `CompileOptions` is now `allow_host` plus two
cosmetic fields. `input`, `output`, `Input`, `Output` and `evaluate`
left `reserved_names` with it — `programs/calc.luc` has a function
called `evaluate` that only compiled because `isReserved` special-cased
the name, and that special case is gone.

**3. Delete the step budget. — DONE.**
*Deletes:* `Budget.steps`, the counter and its branch in the dispatch
loop, `TrapCode.step_budget_exhausted`, one test.
*Proves it safe:* the only production setting is `maxInt(u64)`
(`runner.zig:80`); every other site is a test.
*Forecloses:* a deadline. It never was one — it counts instructions,
not time — and call depth, which is the promise that matters, stays.
*What it took, in contact with the code:* one of the "fifteen tests"
was load-bearing. `06_mir/module.zig`'s single-byte mutation fuzz ran
what it decoded, and the step budget was the only thing that made that
run end — a flipped block index can turn a forward jump into a back
edge, and no engine promises a Luce program stops. `mutation_source`
is now loop-free and the harness skips any mutant whose CFG is not
forward-only, with the skip counted and bounded so it cannot quietly
swallow the corpus. Termination is a property of that corpus, which is
the honest place for it.

### In order — each needs the one before it

**4. Make `.lc` the native artifact.** *(needs 1–2)*
*Changes:* `--emit=library` becomes the default and `.lc` its
extension; serialized MIR keeps the format and loses the user-facing
name; `build.zig` links the bundled programs at install time; the
`.lcn` extension retires. **Take the shared-`libluce_rt` decision
here** — 54× on the bundled payload is the number.
*Proves it safe:* the artifact tag already refuses by name on all four
axes, and `bench/run.sh` leaves stale artifacts in place precisely to
keep that a live test. The site's 173 samples and the nine bundled
programs are the corpus.
*Forecloses:* a `.lc` that runs on another machine. The replacement is
cross-compilation (`--target`, one `libluce_rt` per target, `zig cc`),
which is a step of its own and not a prerequisite.

**5. Delete the fallback.** *(needs 4)*
*Deletes:* `runner.Engine`, `Policy.engine`, `LOOM_ENGINE`,
`runInterpreted`, the `refusal` plumbing, `product.zig`'s
engine-selection tests, and `verify.zig`'s second arm.
*Proves it safe:* after 4, `loom run FILE.lc` needs no compiler at all
— the case the fallback existed for stops existing. `loom luce` and
`loom edit` fail with `native.findCompiler`'s existing sentence.
*Forecloses:* the site's differential check over 148 samples (Hat 5).
Say so in `site/src/verify.zig`'s header rather than letting it vanish.

**6. Move the boundary.** *(needs 5)*
*Deletes from the product:* `backend.zig`'s `Host`, `Terminal`,
`KeyEvent`, `Budget`, `Result`, `Trap`, `Raised`, `FileRead`,
`evaluate`, `evaluateHosted`; `host.zig`'s `host()` and its 23
Zig-signature service functions. `Memory` and `RuntimeValue` move to
`luce.zig`; the rest becomes the oracle's header.
*Proves it safe:* `abi.Host` already carries every service and
`host.zig` already builds both tables from one set of implementations.
*Forecloses:* a second engine slotting in behind a shared boundary.
That was the boundary's stated purpose and it did not happen — LLVM
brought its own published ABI, which is better.

**7. Delete `07_optimize/values.zig` and `flow.zig`.** *(needs 5)*
*Deletes:* 498 lines, on their own headers' instruction.
*Proves it safe:* measured at **-2.5% LLVM compile time, 0% compiled
runtime**; `07_optimize/test.zig` and the instruction-count table are
the check. `registers.zig` stays — `dead.zig` still needs it.
*Forecloses:* nothing downstream; the barrel says "nothing else
depends on it".

**8. Move the executable specification onto the compiled path — as
`agree`. — DONE.** *(needs 1–2; independent of 4–7)*
*Changes:* `behavior_spec` (127), `ownership_spec` (78) and `std_spec`
(19) run their programs through the `agree` harness instead of
`backend.evaluate`.
*Proves it safe:* it is the same 321 programs with a second engine
added, and every disagreement is a finding.
*Costs:* **+66 s**, `zig build test` 71 s → ~137 s. Unavoidable on
every branch of this decision (see Hat 1) — and 58% of the per-test
205 ms is the first `dlopen`, not the compiler, so there is headroom if
it hurts.
*This is the step that makes the oracle self-policing and the step that
gives the shipped engine an executable specification. It is the most
valuable one on the list.*

*What it took, in contact with the code:*

**The specification became a module.** The harness needs `emit`, and
`emit` links libLLVM that `luce` deliberately does not, so the specs
could not stay in the `luce` module and gain a compiled arm. They are
now `src/luce/specs.zig` — the one module that imports both `luce` and
`emit` — built by `build.zig` as its own test target. `luce.zig` no
longer re-exports them. That module boundary produced the rule that
decided every other move in this step, and it is worth stating as a
rule rather than as an accident:

> **Anything that runs a Luce program is a specification, and a
> specification runs it on both engines. Anything that inspects a
> structure is a test of that structure and lives beside the code it
> proves.**

`08_llvm/test.zig` stayed where it is — beside the backend it proves —
and joined the specs module, because it runs programs. `emit.zig` lost
its test block and the `emit` module lost its test target.

**One harness, not five.** `specs/agree.zig` holds what was inside
`08_llvm/test.zig`: `World`, `Provided`, `Capture`, `Reference`, and
the compile → lower → libLLVM → `cc` → `dlopen` path. Two things grew
in the move. The `World` became **seedable** (a file already there, an
argument list, a scripted keyboard, a host that refuses writes) so the
hosted tests could port without losing their exact assertions; and
`settle` now also compares **the world each arm left behind** — file
name and bytes, keys read, lines read, the clock — which the old
`agree` never did. The transcript catches a wrong effect; that catches
a wrong *result* of one. Above the harness sit four spec-facing
assertions (`ok`, `trap`, `errors`, `prints`) plus a `Session` for the
cases that want the exact trace, so call sites read `try agreeOk(src)`
and `try agreeTrap(src, .use_after_free)` and the S1–S43 structure of
`ownership_spec` survives untouched.

**The count is zero, and here is the method.** Every interpreter
entry point is `backend.evaluate`, `backend.evaluateHosted` or
`Machine.execute`:

```sh
grep -rn --include='*.zig' -e 'backend\.evaluate' -e 'machine\.execute' src/
```

Outside `backend.zig` itself, `apps/`, and `specs/agree.zig`, that
leaves **three** sites and none of them runs a Luce program as a
specification:

- `interpreter/test.zig` (2) — `frame_storage` staying O(depth) over
  100 000 calls, and 50 000 frames on a heap stack. Both read
  `Machine`'s internals; neither has a compiled counterpart, because
  compiled code has no frame stack of its own. This is the oracle
  testing itself, which the discipline requires.
- `06_mir/module.zig` (1) — the single-byte damage fuzz. A mutant is
  not a Luce program: no source produces it, nothing says what it
  should print, and the lowering refuses damaged IR by design. The
  interpreter is a **sanitizer** there, and the file now says so.

**Where the other 282 went.** `behavior_spec` 128 → 152,
`ownership_spec` 96, `std_spec` 20 → 24, `errors_spec` 163 → 164
(compile-time only; it runs nothing and never did — the memo's "12 that
execute" was wrong). Four new spec files carry what had to leave the
files it was in: `host_spec.zig` (9, the host boundary),
`modules_spec.zig` (5, several files as one program),
`optimize_spec.zig` (3, the stage changes nothing observable),
`format_spec.zig` (1, a `.lc` read back is the same program).
`interpreter/test.zig` went 36 → 2, `compile/test.zig` 41 → 34,
`07_optimize/test.zig` 12 → 9, `06_mir/module.zig` 10 → 9. Nothing was
dropped: 836 → **838**, the two extra being std `files` coverage that
had no home before.

**No disagreement was found.** 282 programs moved onto the compiled
path and every one agreed on the first run — prints, trap code, trap
message, trace frame for frame, leak census, and the world left
behind. That is the lowering being total rather than the harness being
weak, and the proof is the negative control: swapping `.smin` for
`.smax` in `lower.zig`'s `emitExtremum` is caught by
`behavior_spec`'s "abs, min, max, clamp on Int", by "loops, recursion,
strings, and builtins compute", and by a *generated* program in
`optimize_spec`'s fuzz — not only by `08_llvm`'s own agree tests. The
specs police the shipping engine now.

**The cost was double the estimate, and the reason is a decision, not
a surprise.** 71 s → **~4 min**. Roughly 60 s of that is the 282
specs, at ~130 ms per compiled run rather than the 205 ms Hat 1
measured. The other ~120 s is `optimize_spec`'s fuzz, which the memo
never priced: 400 generated programs, each compiled twice (stage off,
stage on) and each of those run on both engines. That is 800 compiled
runs, and it is deliberate — it is four hundred programs nobody wrote,
and it is the widest differential net over the lowering in the tree,
recovering exactly the coverage Hat 5 says dies with the site's second
arm. It is also the single line to cut if the suite ever hurts: run
only the optimized program compiled and the bill halves.

**9. The prose.** *(after 5)*
232 sites, 44 files. Four sections rewritten rather than edited. Fold
this memo's conclusions into `docs/CODEGEN.md` and `docs/PIPELINE.md`
and leave this file as the record.

### Not on this list, on purpose

Cross-compilation (`--target`), the shared-`libluce_rt` implementation,
the second front-end binary that would take dyld off `luce check`, and
letting the agree harness read the site's sample corpus. All four are
good; none of them is the retirement, and none of them blocks it.

---

## The one-line summary

The interpreter is 1,074 lines that ship in a binary they should not
ship in, back a fallback that a native `.lc` makes unnecessary, and
carry an executable specification that belongs to the other engine.
Move the specification, delete the engine, keep the oracle.
