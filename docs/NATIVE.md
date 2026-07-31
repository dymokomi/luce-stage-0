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
string slices, `len`, Builder appends — get *fast* direct services
that skip the marshaling and mirror the interpreter's checks in a
few lines each; the oracle holds both tiers to byte-identical
behavior.

Current standing (docs/BENCHMARKS.md): **loops ~2.9x C, math
~1.5x C, arrays ~5.5x C, strings ~19x C** — every bench native,
5-9x faster than the interpreter on the collection-bound ones.
Known limits recorded on purpose: `budget.steps` is not enforced
natively (the call-depth budget is; loom runs scripts unlimited
anyway), and a native trap reports its innermost frame only — the
interpreter remains the engine with full call traces.  The next
speed lever, when a real program demands it: unboxed native storage
for scalar arrays and strings, turning the per-element service call
into an inline bounds-checked load.

## Where a wall would send us

The engine seam is the contract: everything above it (`backend.zig`
upward) is engine-blind.  If MIR's ~2-3x plateau ever stops being
enough, the same lowering structure feeds a self-written Zig backend
(sovereignty) or an LLVM-backed one (the last 2x and SIMD) — racing
under the same oracle and the same bench table, exactly as this one
was brought up.
