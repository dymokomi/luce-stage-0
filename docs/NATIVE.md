# The native engine — Luce compiled to machine code at load

loom runs compiled Luce two ways, behind one seam, with identical
semantics:

- **the interpreter** (`src/luce/interpreter.zig`) — the reference
  implementation and the spec; runs everything, everywhere, with
  full call traces;
- **the native engine** (`src/luce/native.zig`) — lowers the
  verified IR to machine code in-process through the vendored MIR
  JIT (`vendor/mir`, MIT, ~20k lines of C we build with our own
  compiler) and jumps to it.  x86-64 and aarch64; Linux, macOS,
  Windows.  Nothing is installed, spawned, or written to disk —
  the JIT lives inside loom.

`loom run` picks the native engine whenever the whole program fits
its supported core, the interpreter otherwise; `LOOM_ENGINE=
interpreter` forces the reference engine.  Programs cannot tell
which engine ran them — that is the invariant everything below
serves.

## Semantics are compiled in, not approximated

Every checked operation lowers *with its checks*: `addo`/`subo`/
`mulo` plus branch-on-overflow for Int arithmetic, explicit zero and
MIN/-1 guards before division, NaN and range guards before
`Int(Float)`, the call-depth budget as a counter the prologue
decrements.  Traps carry the same stable codes, the same messages
(`trap("...")` included), and resolve the same origins tables to
`file:line:column`.  The two-engine oracle (`native_spec.zig`) runs
a corpus through both engines and demands identical prints, trap
codes, and messages — the same discipline Zig uses to keep its
self-hosted backends honest against LLVM.

The oracle is only as strong as its corpus.  A 2026-07-31 audit
found struct `==` compiling to a comparison of field-array
*addresses* — equal structs read as unequal natively — because the
corpus had no struct-equality case; the lowering now routes strukt
comparisons through the reference implementation and the corpus
covers them.  The standing rule that fell out: every operator ×
operand-type pair the analyzer admits belongs in the corpus, not
just the pairs the benchmarks happen to exercise.

## How the lowering works

The verified IR prints as one MIR module in MIR's textual form and
`MIR_scan_string` assembles it — text keeps the C binding surface to
a handful of functions (`mir_glue.c`); no MIR structs cross the
boundary.  Luce locals map to MIR registers directly (MIR is
register-based with mutable virtual registers, exactly our locals'
shape), blocks to labels, and MIR does the register allocation and
optimization.  Every emitted function takes a state pointer first;
traps store three words (code, function, instruction) into it and
unwind through default returns, every call site checking one word.
The hot path never reads any of it.

Heap-shaped work crosses a small C-ABI services table into loom's
Zig runtime (`svc_print`, `svc_str_*`, …) — the ownership model and
host boundary stay implemented in exactly one place.

## Milestone 2: the whole language

The native core now takes everything a script can be — collections,
ownership verbs, structs, strings, the std modules, the host
builtins.  What stays off it: evaluator-mode ports, the Bytes stub
type, the dormant fabric intrinsics, and non-finite folded float
constants — the interpreter is now the fallback for platforms and
edge shapes, not for features.  Real programs (sort, dice, the
editor's machinery) run native.

Two service tiers make that work.  Heap-shaped instructions marshal
their operands into the State's scratch slots and call a *generic*
service that looks the instruction up and runs the interpreter's own
implementation — full semantic reuse, ideal when the operation does
real work (sort, split, allocation, host IO).  The hottest cheap
primitives — sequence indexing over scalar elements, `byte_at`,
`find_byte`, string slices, `len`, Builder appends, `chr`,
`str(Int)`, string `+` — get *fast* direct services
that skip the marshaling and mirror the interpreter's checks in a
few lines each; the oracle holds both tiers to byte-identical
behavior.

Known limits recorded on purpose: `budget.steps` is not enforced
natively (the call-depth budget is; loom runs scripts unlimited
anyway), and a native trap reports its innermost frame only — the
interpreter remains the engine with full call traces.

## Milestone 3: unboxed access

The hottest primitives no longer call anything.  A String travels
natively as the address of a stable `{ptr, len}` descriptor —
`byte_at` compiles to a bounds check and a byte load, `len` to one
load.  A scalar Array (any rank) travels as the address of a *view*
— its element storage, `dims[0]`, the address of the object's alive
flag, and its handle — so rank-1 indexing compiles to inline
null/alive/bounds checks and a typed load or store at
`elements + index * stride + payload_offset`.  The payload offsets
inside RuntimeValue are measured at run time (the union's layout is
the compiler's business) and embedded in the emitted text as
immediates, together with the constant-pool descriptor addresses.

The data itself never moved: views point into the interpreter's own
heap objects (heap cells are arena-allocated and pointer-stable
precisely for this), the element tags are never touched by payload
writes, and every other operation converts view/descriptor back to
handle/slice at the service boundary.  `free` through any alias
still traps inline — the view checks the object's real alive flag.
Ownership, sort, fill, copy: all still the interpreter's one
implementation.

## Milestone 4: the producers, and one call Zig can vectorize

Milestone 3 made *reading* a string free; milestone 4 went after
*producing* one.  Measuring the tiers (docs/SPEED.md §10) found the
cost was the generic boundary itself — `ord`, which allocates
nothing, cost 20.7ns against a slice's 5.4ns — so `chr`, `str(Int)`
and string `+` moved to fast direct services, each still ending in
the OOM check that keeps a null descriptor from escaping.

Two primitives joined the language with them.  `b.append_ascii(code)`
appends one ASCII byte with no String to carry it (ASCII only —
a Builder's bytes become a String, and String is valid UTF-8).
`s.find_byte(byte, start)` is to scanning what `byte_at` is to
access, and it is the interesting one: as a single call into Zig it
picks up `std.mem`'s block-vector search, which is how SIMD reaches
a backend that cannot vectorize.  std strings keeps the substring
algorithm in Luce and merely stopped spelling its inner scan as a
Luce loop.

Current standing (docs/BENCHMARKS.md): **math ~1.2x C, loops ~1.2x
C, arrays ~3x C, strings ~11x C** — the checked-scalar plateau a
non-vectorizing backend can reach.  What is left in the strings
ratio is no longer string-shaped: JIT compile time for std
functions the program never calls, and `List.append` on the generic
path behind `split`.

## Milestone 5, first half — hermetic code (shipped)

Luce is a compiled language (docs/SPEED.md §13); what kept its last
compile stage at load rather than at build was only that the emitted
code baked in addresses valid for one process.  The milestone-4
audit's inventory — constant-descriptor addresses and the "" zero
value as text immediates; the 18 `svc_*` symbols resolved by
`MIR_load_external`; inter-function call targets baked in by MIR
itself (movz/movk immediates on aarch64, a constant-pool word on
x86-64) — is now empty.

**The mechanism is an address table, and the lowering cannot leak
what it never sees.**  State is allocated with a tail: services
first (the order of `native.zig`'s `services` array), then one entry
per constant descriptor plus the trailing "", then one entry per
Luce function.  Every call target and every constant-string
reference compiles to one load off the state register —
`mov t, i64:OFF(s); call proto, t, ...` — which MIR's call
instruction takes natively (a register target; both backends emit
`blr`/`call *r`), so the vendored JIT needed no change for it.  The
emitted module has **no imports and no forwards**; `lowerProgram`
computes table offsets and never touches an address, and `run()`
fills the table — the single place host addresses exist.  What
remains as immediates is exactly the loom-build-stable set: the
RuntimeValue payload offsets and stride, to be guarded by a build
fingerprint when code persists.  (Runtime string descriptors, array
views, and struct field arrays still flow through registers as
data — they need ABI stability, not relocation, and always did.)

**Enforcement is the hermeticity oracle** (`native_spec.zig`):
compile the same program in two fresh MIR contexts — different code
pages, different would-be addresses — and demand byte-identical
machine code per function, through `native.generatedCode`, the
capture seam the image will reuse.  The instrument is validated in
both directions: planting one direct symbolic call back into the
lowering makes it fail; the shipped lowering passes.  The code
spans come from a three-line `LUCE PATCH` on the owned vendor
snapshot (MIR kept each function's code address but dropped its
length; see vendor/mir/LUCE-VENDOR.md).

Measured cost: none.  `bench/compare.sh` reads every bench within
noise (±1%) — the feared loss of MIR's link-time inlining did not
materialize, and one table load is no worse than materializing a
64-bit absolute address inline.

## Milestone 5, second half — the image (shipped)

`loom run FILE.lc` now keeps a **`.lci` image** beside the `.lc`
(`image.zig`; `LOOM_IMAGE=off` disables): the first run JITs and
writes it, every later run maps the machine code into executable
pages — the same MAP_JIT + `pthread_jit_write_protect_np` +
`sys_icache_invalidate` recipe as the JIT's own allocator — fills
the State address table, and calls the entry.  **No code
generation, no MIR context.**  The `.lc` stays the only portable
artifact; scripts (`.luc`) compile in memory and never touch
images.

Validity is three keys checked cheapest-first, plus integrity: the
ABI fingerprint (`native.fingerprint()` — target, layout offsets,
the service roster whose order is the table's), the `.lc` bytes'
hash, and the **lowered-text hash** — lowering is pure and costs
well under a millisecond, so `loom` recomputes it at load and any
change to the code generator invalidates every image automatically,
with no version constant to remember to bump.  A body hash guards
the code bytes themselves: a torn write or flipped bit is a clean
cache miss (the pre-hash prototype jumped into corrupt machine code
— that segfault is now a unit test).  Every rejection falls back to
the JIT, which rewrites the cache; the interpreter remains the
per-program fallback beneath that.

Building it flushed out the one absolute address M1 had missed:
**MIR turns a float immediate into a module data item and bakes the
item's malloc address into the code** (movz/movk on aarch64).  The
two-context hermeticity oracle had been blind to it because
sequential contexts free and reallocate at identical addresses —
identical bytes, leaked address.  Both are fixed: float constants
now travel through the State table *as bit-pattern values* (the one
table section that is pure data, position-independent by nature —
`Int(Float)` range limits and the float zero included), and the
oracle holds both contexts alive simultaneously so allocator reuse
can never mask an embed again.

Measured (M4 Max): a warm run drops exactly the codegen —
`strings` −3.3ms (~5%), the do-nothing floor 2.0 → 1.6ms; big
single-function benches move within noise.  What remains at load:
read + decode + verify the `.lc`, hash the lowered text, map pages,
fill the table.

## The Zig backend (M0, opt-in)

The self-written backend of docs/SPEED.md §16-18 lives in
`codegen.zig` and is reached with LOOM_ENGINE=zig: Luce IR emitted
straight to aarch64 machine code — no MIR, no C — against the same
`native.abi` contract (State offsets, address table), producing the
same hermetic spans, mapped and run by the same image.map +
native.runCode path.  Since milestone 2 it covers **everything the
MIR core covers** — floats as a second register class (pinned
d8-d12, pool d13-d15, all callee-saved), Int(Float) with the NaN
and range guards, multi-function calls over the C ABI, the
ownership serial in x28 and return loosening, the full
generic-service marshaling, every fast service, inline view and
string access — its gate is `native.supported()` narrowed only by
ABI limits (register-passed arguments), and the runner ladder falls
zig → MIR → interpreter.  The oracle runs its whole corpus on all
three engines; real programs (sort, dice, stats, wordcount) agree
byte-for-byte.

Standing: loops/strings/math at **1.02-1.05x MIR**, arrays at
~1.37x — the one open gap is loop-invariant hoisting of the inline
view checks, which MIR's GVN gets and this backend does not yet
attempt (recorded, not disguised; it is also where vectorization
work lands later).  Targets: aarch64 macOS/Linux now, x86-64 Linux
next, Windows when image.zig grows VirtualAlloc.

## Where a wall would send us

The engine seam is the contract: everything above it (`backend.zig`
upward) is engine-blind.  If MIR's ~2-3x plateau ever stops being
enough, the same lowering structure feeds a self-written Zig backend
(sovereignty — and designed position-independent from day one, the
milestone-5 image becomes its native output) or an LLVM-backed one
(the last 2x and SIMD) — racing under the same oracle and the same
bench table, exactly as this one was brought up.
