# How Luce got fast — the execution-speed decision record

The full path from the first benchmark to the native engine, kept
the way docs/MEMORY.md keeps the memory-model debate: every option
weighed, every number measured on this machine, every rejection
recorded with its reason — so the absence of an alternative reads
as a choice, not an oversight.  Written 2026-07-31, the day
milestone 1 of the native engine shipped.

---

## 1. The first benchmark, and a wrong number

The suite (docs/BENCHMARKS.md) was built first: paired C and Luce
programs — same algorithm, same printed output, outputs
cross-checked before anything is timed — covering tight integer
loops, float math (mandelbrot), string manipulation through std
strings, and an array dot product that C auto-vectorizes.  C
compiles `zig cc -O3 -march=native`; one real finding fell out
immediately: `-ffp-contract=off` is required, because Luce
guarantees strict IEEE with no fused multiply-add and with FMA on,
the mandelbrot membership counts genuinely differ by a few pixels.

First published result: **150–300× slower than C, ~3× slower than
CPython.**  Alarming — and wrong.

## 2. The correction: the interpreter was a Debug build

The `.lc` was `--release` and C was `-O3`, but `./build.sh` ran a
bare `zig build`, whose default is Zig's Debug mode — the
*interpreter binary itself* was unoptimized.  Measured across
modes (loops bench):

| interpreter build     | loops  | vs C   |
|-----------------------|--------|--------|
| Debug (never bench)   | ~3.9s  | ~240×  |
| ReleaseSafe           | ~0.97s | ~60×   |
| ReleaseFast           | ~0.87s | ~53×   |

Honest standing: **40–95× C, faster than CPython 3.11** on the
loop-bound workloads.  Decisions taken: `build.sh` defaults to
ReleaseSafe (the interpreter is a trust boundary — `.lc` runs like
an executable — so Zig's own checks stay on at ~15% over
ReleaseFast), and benchmarking a Debug interpreter is permanently
labeled meaningless.

## 3. "Shouldn't the checks be compile-time?" — no, and here's why

The instinct was to blame runtime checking and want it static.
Finding: most checks already *are* static (types, ownership
classes, poisoning, return paths, arity).  What remains at runtime
is exactly what cannot be static — bounds of dynamic indices,
overflow of runtime values, the set Zig's ReleaseSafe keeps — and
the measured ceiling for **all** of it is the
ReleaseSafe↔ReleaseFast gap: **~15%**.

The real cost was interpretation itself: a Luce `+` cost a trip
around the dispatch loop — fetch, tagged-union switch, register
array traffic, budget decrement — 15–30 machine instructions where
C spends one.  Deleting every check would have moved ~60× to ~50×,
not to 1×.  Conclusion, load-bearing for everything after: **the
path to C is not fewer checks; it is not dispatching at all.**

## 4. What "compiled" actually means here

Two clarifying rounds followed, both worth keeping:

- **A dynamic library is packaging, not speed.**  The CPU runs the
  machine code inside a `.so` at exactly the quality that code has;
  dlopen confers nothing.  Only the compiler that *generated* the
  code decides the speed.  Producing a dylib when loom generates
  its own code would just add a linker (ELF **and** Mach-O) and a
  disk round-trip to arrive where a JIT starts: native code in
  executable pages, one call away.
- **Persistence isn't needed.**  Modules are kilobytes; baseline
  code generation runs at tens of MB/s; compiling at every load
  costs well under a millisecond.  If pre-warmed caches ever
  matter, the right artifact is our own trivial format (code +
  relocations + origins, mmap'd), not host dylibs.

The architecture settled: **`.lc` is the portable, verified
distribution format (the WASM role); loom is the runtime that
compiles it to native code at load, in-process** — the JVM/ART/WASM
pattern.  The interpreter stays as the reference implementation.

## 5. Routes proposed and rejected

- **Emit C, drive `zig cc`, dlopen the result.**  Proven end to end
  in this container (checked arithmetic via builtins, service
  table, correct checksums).  Rejected: ships a toolchain.
- **Emit Zig source instead** — cleaner traps (`try` propagation),
  first-class cross-compilation (all four targets built from one
  Linux box in the experiment), one toolchain.  Also proven, also
  rejected, same reason: Zig is what LuciaOS is *written in*, not
  something users install.  One durable lesson survived: Zig error
  unions have no stable ABI across compilations, so any dlopen-ish
  boundary must be C ABI — which became the services-table design.
- **Requirement crystallized:** loom alone, minimal dependencies,
  fast at load, nothing external ever invoked.  Ingesting open
  source *into* loom is acceptable; invoking installed software is
  not.

## 6. The option survey, with the Houdini correction

"C-class" is decided by exactly one thing — instruction selection
and register allocation.  The survey of whose to use:

| option | realistic vs clang -O3 | verdict |
|---|---|---|
| Vendor LLVM (Julia's route) | 1.0–1.2×, SIMD included | open source (Apache 2.0 + exceptions), every platform; but ~25M lines of C++, +100–200MB binary (the local `zig` binary is 173MB, mostly LLVM), 6-month API churn.  Priced, deferred, never off the table. |
| Vendor Cranelift | 1.1–1.6× | drags cargo/Rust into a pure-Zig build |
| **Vendor MIR** | **measured below** | ~20k lines MIT C, in-process JIT, x86-64 + aarch64, Linux/macOS/**Windows (CI-tested, Win64 ABI in source)** |
| libtcc / sljit / lightning / copy-and-patch | 2–8×, no real regalloc | not C-class |
| QBE | ~1.4× | emits textual assembly — needs an assembler at runtime |
| Own Zig backend | 1.5–3× at plateau (Go's neighborhood) | months; full sovereignty; the OS endgame |
| VEX-style batching | ~1× on bulk array ops only | complement, not answer |

The Houdini/VEX legend, corrected: VEX is not a magic compiler but
a **batch-SIMD interpreter** — one dispatch processes thousands of
points, so dispatch amortizes to nothing, plus threading.  Near-C
only because the domain is data-parallel.  The transferable idea is
whole-collection native std intrinsics (dot, fill) — cheap, real,
and orthogonal to general code.

**Prior art aligned on one architecture.**  Zig: one typed IR (AIR)
with many backend lowerings — LLVM for release, its own x86-64
backend for debug builds, one behavior suite across all backends.
Swift: one semantic IR (SIL) carrying what LLVM can't see
(ownership, ARC), optimized there, then lowered.  Rust: same shape
(their unrelated "MIR").  Luce's IR is SIL-shaped — it carries
ownership as instructions — and the seam design (`backend.zig`
above, interchangeable engines below, oracle across them) is
exactly Zig's practice.  Also answered along the way: Swift is
1.0–1.5× C *because* it borrows LLVM; Zig programs are fast because
the language adds zero mandatory runtime atop LLVM's optimizer; the
zig compiler is fast because they wrote their own debug backend —
the two-backend strategy this plan copies.

## 7. The MIR experiment — deciding with data

MIR cloned, built in seconds, and raced against clang -O3 **on our
own benchmark C files** through its c2mir JIT (outputs identical,
~4ms compile overhead):

| bench | clang -O3 | MIR JIT | MIR/clang |
|---|---|---|---|
| loops | 15.6ms | ~40ms | 2.6× |
| math | 18.2ms | ~33ms | 1.8× |
| strings | 4.8ms | ~36ms | 7.4× |
| arrays | 7.5ms | ~32ms | 4.2× |

~2–2.5× C on scalar loop code with a real register allocator; weak
where LLVM vectorizes.  Risks accepted knowingly: single-maintainer
upstream (mitigated by full ingestion — 20k readable lines we can
own), no vectorization (the `arrays` plateau, recorded).

## 8. The decision

**Three engines racing behind one seam, one at a time:**

1. **Now: vendor MIR** (`vendor/mir`, pristine, commit pinned) as
   the optimizing backend — weeks of work for ~90% of the practical
   win at ~1% of LLVM's weight.
2. **Unhurried: the self-written Zig backend** behind the same
   seam, racing MIR under the same oracle and bench table;
   sovereignty when it wins.  (Honest expectation: it *starts* at
   5–10× as a baseline and catches MIR only with register
   allocation; it can eventually beat MIR by exploiting what a
   generic JIT can't know — no aliasing across objects, fixed
   layouts.)
3. **If walled: LLVM** as one more implementation of the same
   lowering, via its stable C API.  "Effortless switching" defined
   honestly: mechanical — one file, ~30 operations, no
   re-architecting above the seam.

Supporting decisions: no new IL (the verified Luce IR *is* the
portable one — the Swift lesson says keep semantics in it);
semantics never vary by engine (every check compiles in; the
two-engine oracle enforces prints byte-for-byte and traps
code-for-code, the Zig discipline); per-program fallback to the
interpreter, never mixed engines.

## 9. The outcome (milestone 1, same day)

Lowering via MIR's textual form (five glue functions, no C structs
across the boundary), services table for everything heap-shaped,
trap protocol in four words of state the hot path never reads:

| benchmark | C | native | interp | native/C |
|---|---|---|---|---|
| loops | ~13ms | ~37ms | ~860ms | **2.9×** |
| math | ~15ms | ~23ms | ~1.0s | **1.6×** |
| strings | ~4ms | (fell back) | ~415ms | — |
| arrays | ~6ms | (fell back) | ~343ms | — |

Startup, decode, and the ~1ms JIT compile included.  23–43× faster
than the interpreter, checks and identical trap semantics included,
landing inside the band the section-7 experiment predicted.

The running summary of the whole record: **measure before
believing (§1–2), name the actual cost (§3), separate packaging
from speed (§4), buy the proven 90% (§7–8), keep the seam that
makes every future option cheap (§6, §8).**  Milestone 2 —
collections, ownership, strings in the native core — continues in
docs/NATIVE.md.

---

## 10. The strings gap, measured instead of assumed

After milestone 3 the `strings` bench was the one embarrassing
column, and the standing explanation — recorded in
docs/BENCHMARKS.md — was "allocation-per-operation".  Measuring it
on an Apple M4 Max (the first non-Linux host this project has run
on) said otherwise.

**The harness was flattering us first.**  `bench/run.sh` timed with
`start=$(date +%s%N); cmd; end=$(date +%s%N)`, and the second
`date` fork lands *inside* the interval: ~1ms of overhead on top of
the ~1.3ms process floor, added to both columns.  When the Luce
side was ~1s of interpreter that was noise; at 8–15ms of native
code it compresses ratios badly — the table read `strings 3.8x`
where direct-exec timing read ~14x, which is what docs/NATIVE.md
had claimed all along.  **A constant added to both sides of a ratio
is not neutral.**  The ratios in a run.sh table are a lower bound
on the real gap; compare.sh deltas, being like-for-like, are not
affected.

**The cost model.**  Timing each primitive at 5M iterations
separated the tiers cleanly:

| operation | ns | tier |
|---|---|---|
| loop iteration, `len(s)` | 0.30 | inline |
| `s.byte_at(i)` | 0.50 | inline (milestone 3) |
| `s[a:b]` | 5.4 | fast service (allocates a descriptor) |
| `ord("a")` — **allocates nothing** | 20.7 | generic service |
| `chr(65)` | 27.0 | generic service + allocation |
| `str(i)` | 41.0 | generic service + allocation |

`ord` allocates nothing and still costs 20.7ns; `s[a:b]` allocates
and costs 5.4ns.  So the string cost was **the generic dispatch
boundary (~20ns) — instruction lookup, slot marshaling,
RuntimeValue staging — not allocation (~6ns) and not the byte work
(~0.5ns)**.  The old explanation had the wrong noun.  The model
predicts the benchmark: fold_case at 80k folded bytes × (chr 27 +
slice 5.4 + two appends 12.4) = 3.6ms predicted, 3.7ms measured.

**Three changes followed, in the order the model ranked them.**

1. *Free, in Luce.*  `find_from` hoists its lengths and gates the
   inner compare on a first-byte test; `fold_case` stops appending
   the empty run left between adjacent folded bytes.  No engine
   change: count −71%, replace −35%, split −33%, upper −21%.
2. *Fast services for the string producers* (§9's second tier,
   extended): `chr`, `str(Int)`, and `+` stop marshaling through
   the generic path.  Each still ends in an OOM check — a failed
   allocation leaves a null descriptor, and nothing may run on with
   one.
3. *Two new primitives.*  `b.append_ascii(code)` puts one ASCII
   byte in a Builder without the String a `chr()` would allocate
   (ASCII only: a Builder's bytes become a String, and String is
   valid UTF-8).  `s.find_byte(byte, start)` is the scanning
   primitive that `byte_at` is the access primitive — and because
   it is one call into Zig, it gets `std.mem`'s block-vector search
   for free, which is the only way SIMD can ever enter a
   non-vectorizing backend (§6's "whole-collection intrinsics",
   arriving in a second domain).

The primitives were chosen so std strings stays *written in Luce*:
`find_from` still owns the substring algorithm, it just stopped
spelling the inner scan as a Luce loop.  Rejected on that ground: a
native `str_find`/`str_upper` intrinsic pair, which would have been
faster still and would have moved the library into the engine.

**Result** (M4 Max, direct-exec timing, process floor included):

| phase (10x) | before | free Luce | + engine |
|---|---|---|---|
| upper | 37.1ms | 29.5ms | **6.1ms** |
| build (`str(i)` × 200k) | 15.2ms | 15.2ms | **8.8ms** |
| replace | 7.5ms | 4.9ms | **4.6ms** |
| count | 5.4ms | 1.6ms | **1.1ms** |

The bench itself: **14.03ms → 9.78ms (−30%)**, ~14x C down to
~11x; the interpreter, which inherits the same std and the same
`find_byte`, went 140ms → 58ms.  `bench/compare.sh HEAD` reads
**strings −27.2%** with loops, math, and arrays flat.

**What this leaves.**  The 9.78ms is now roughly 1.9ms process
startup, **4.1ms JIT compile**, and 3.9ms of actual execution — so
compiling the code outweighs running it, and §4's "compiling at
every load costs well under a millisecond" is false once a std
module is imported: `import strings` costs +4.1ms under the native
engine and −0.1ms under the interpreter (measured both ways; it is
JIT time, not decode), and the bench calls 7 of the module's 18
functions.  The next lever is therefore not a string lever at all:
**do not compile what is not reachable from `main`** — static
pruning before lowering, or lazy per-function compilation.  After
that, `split` is bounded by `List.append` on the generic path, not
by anything string-shaped.

---

## 11. Measuring computation, not overhead

§10 ended with a JIT compile that outweighed the work it compiled.
Three ways out were put to the question — cache the compile, exclude
it from the numbers, or make the workload big enough that it stops
mattering.  The third is right, and the other two are worth
recording as rejected.

**Cache the compiled code?  Not yet, and not first.**  The emitted
code is not relocatable: service addresses arrive through
`MIR_load_external`, and constant string-descriptor addresses and
the measured RuntimeValue payload offsets are embedded in the text
as immediates.  Caching therefore means emitting a relocation table
and inventing the artifact §4 sketched (code + relocations +
origins, mmap'd), plus a cache keyed on both the `.lc` and the loom
build.  All of that to avoid compiling ~18 functions.  **Pruning
what is never called is strictly smaller and strictly better** —
no on-disk format, no invalidation, and it helps the first run too.
Caching stays available if a program ever imports enough std that
even the reachable set is slow to compile.

**Exclude the compile from the numbers?  That would trade one bias
for another.**  C pays its own process startup in every row; taking
loom's fixed cost out while leaving C's in flatters Luce exactly as
much as the old harness flattered it in the other direction.  What
the reader needs is not a number with the overhead hidden but a
number where overhead is small *and visible* — so `bench/run.sh`
now prints a `floor` row (a do-nothing program through the same
harness), and the benchmarks are sized against it.

**Size the work so the fixed cost is noise.**  The benchmarks were
sized for a ~1s *interpreter* run; the native engine then made them
10ms, and nobody re-sized them.  At that size the fixed ~6ms was
most of the measurement.  They are now ~20x (loops/math scale the
side, `arrays` its repeat count, `strings` its item count), which
puts native near 100ms and the floor under 10%.  The corrected
picture is much better than §10's:

| benchmark | C | native | native/C | (§10 said) |
|---|---|---|---|---|
| loops | ~81ms | ~90ms | **~1.1x** | ~1.4x |
| math | ~140ms | ~158ms | **~1.1x** | ~1.2x |
| arrays | ~44ms | ~81ms | **~1.8x** | ~3.1x |
| strings | ~20ms | ~74ms | **~3.6x** | ~11x |

**strings is ~3.6x C, not ~11x.**  The 11x was real for a 10ms
program — it is what a short script actually experiences — but it
was mostly startup and JIT, not string work.  Both numbers are
true of different questions, and the benchmark should answer the
one about computation.

**What the resize exposed.**  Scaling the interpreter column 20x
took `strings` to **3.1 GB** of resident memory.  The cause was not
strings at all: `pushFrame` took each frame's registers and locals
as a fresh slice of the run arena, and the arena never reclaims —
so interpreter memory grew with the number of calls a program
*made*, not with what it held.  A 3M-call loop cost 414 MB, and any
long-running interpreted program would eventually die of it.
Frames now take one contiguous run of a reusable `frame_storage`
stack, popped on return, with frames holding offsets rather than
slices (the storage reallocates as the stack deepens, and offsets
survive that); call arguments use one reused scratch buffer instead
of a per-call arena slice.  Memory became O(depth) instead of
O(calls) — 3M calls **414 MB → 2 MB**, strings-20x **3156 MB → 55
MB** — and it is *faster*, because the allocation per call is gone:
**−23.7%** on the call-heavy program, **−15.8%** on strings.

The lesson generalizes past this file: **an arena is a lifetime
policy, and "the whole run" is the wrong lifetime for anything
per-call.**  What remains arena-shaped is per-value (strings,
descriptors, heap objects), which is bounded by the data a program
touches rather than by how long it runs.

---

## 12. Are we a compiled language?  Not yet — and the benchmark is right to say so

The question was put directly: Luce compiles `.luc` to `.lc` and then
runs it, so — like C, C++, Zig — compile time should not be in the
benchmark; and if it is, something is wrong.

**Today it is not wrong, because we are not that kind of compiled.**
§4 settled the architecture as *the JVM/ART/WASM pattern*: `.lc` is
the portable, verified distribution format, and loom generates
machine code at load, in-process.  That is `javac` → `.class` → a
JIT, not `zig build-exe`.  Java is colloquially "compiled" too, and
nobody excludes JIT time from a Java benchmark.  **While loom
generates code at every load, that time is part of what every user
experiences, and subtracting it would measure a program that does
not exist.**  So the benchmark keeps it, and the `floor` row makes
it visible (§11).

**Where the load-time compile actually goes** (19 functions, 47KB of
MIR text — measured with temporary instrumentation, since removed):

| phase | time | share |
|---|---|---|
| our lowering to MIR text | 199us | 3% |
| `MIR_scan_string` (parsing that text) | 1228us | 21% |
| `MIR_link` with `MIR_set_gen_interface` | 4551us | **76%** |
| `MIR_gen` per function | 8us | 0% |

`MIR_gen` looks free because it is: linking with the gen interface
already compiled everything, eagerly, including every function the
program never calls.

**The fix that was available regardless of the architecture** is the
one a compiled language is expected to have: **dead-code
elimination**.  `ir.prune` drops every function unreachable from the
entry, in the compiler, before the artifact is written — call targets
and the entry are the only function references in the IR, so it is a
mark and a renumber, and the verifier re-checks the result.  A
program that imports `strings` and calls none of it:

| | before | after |
|---|---|---|
| `.lc` size | 12308 B | **178 B** |
| load-time compile | +4.11ms | **free** |

The benchmarks barely move (`strings` −1.4%) because they use most
of what they import — which is the honest shape of this win: it is
worth ~4ms to every *script*, and nearly nothing to a benchmark.
`programs/editor.lc` is unchanged at 51KB; it calls everything it
defines.

**Rejected on the way.**  MIR offers `MIR_set_lazy_gen_interface` —
compile each function on first call — which would have got most of
the same win for one word.  Two reasons not to.  It makes loom *more*
HotSpot-shaped, not less, which is the wrong direction for this
question; and it is unsafe as the engine stands: `luce_mir_protected`
establishes a `setjmp` and returns, so a MIR error raised during
lazy generation — that is, during *execution* — would `longjmp` into
a dead frame.  Making it safe means running the program itself
inside the protected region and accepting a `longjmp` out of
arbitrary native Luce frames with the Machine's heap mid-operation.
Static pruning has neither problem.

**What would actually make us C-shaped**, recorded now so the next
edition does not re-derive it.  The blocker is not that we lack a
cache; it is that the emitted code bakes in addresses valid for
exactly one process:

1. service addresses arrive via `MIR_load_external`, and **ASLR
   moves them every execution** — they cannot be persisted at all;
2. constant string-descriptor addresses are arena-allocated per run
   and embedded as immediates;
3. RuntimeValue payload offsets are measured at run time and
   embedded (these at least are stable for one loom build).

So AOT is not "write the code to disk"; it is **emit code with no
host absolute addresses in it**.  The lever is already in place:
every emitted function takes `state` as its first argument, so the
externals can move behind it — `state->services[N]` as an indirect
call, `state->constants[N]` as a descriptor table — leaving payload
offsets as immediates guarded by a loom-build fingerprint.  The code
then becomes position-independent with respect to the host and can
be written once and mmap'd, at the cost of one indirection per
service call and an audit of whatever references MIR emits to its
own runtime helpers.

The artifact should be a *second* one, not a replacement: `.lc` stays
portable and verified (that is its whole job, and cross-machine
distribution depends on it), with a host-specific image beside it
keyed on the `.lc` hash, the loom build, and the target triple —
ART's dex2oat, .NET's ReadyToRun.  `loom run` uses the image when it
is valid and JITs when it is not, so nothing about §4 or §8 has to
be given up to gain it.

Standing recommendation: with pruning landed, a small program's
load-time compile is ~0.3ms and a std-heavy one's is ~3-5ms.  Do AOT
when the goal is *the model* — being able to say a `.lc` runs without
a compiler in the loop — rather than when the goal is the
milliseconds, which are now small and getting smaller from the other
end.
