# The self-hosting program — FFI, the Luce-written compiler, and the freeze

**Status: FROZEN (owner, 2026-08-23).** The language is locked as
stage 0. Every pre-freeze ruling landed and gated: Tier-1 FFI whole
(extern/foreign/blocking, --link, std.c scoped buffers, build-plan
links), indirect unions (D20), positional match captures (D21),
fallible function values (R3), typed union errors (R2), the channel
half of cancellation (receive_by + os.Deadline), and the std sweep
(json/zip/http error unions). The readiness probe — a compiler slice
using every feature at once — compiled first try. From here the Zig
toolchain has two jobs, oracle and bootstrap seed; **toolchain**
changes (bug fixes, DWARF line tables, artifact work) remain
welcome, and the language accepts only **purely additive, purely
syntactic** revisions that invalidate no frozen-era source — the
freeze is on language *capability*, which is complete. (0.19 added
inline single-statement blocks under exactly that bar: same AST,
same MIR format, same host ABI, every 0.18 program still valid.)
New language *capability* is over; that is stage 1's job. The next compiler is written
fully in Luce, in its own repository, against this frozen seed.

**Freeze amendment (owner, 2026-08-24): the native boundary is
exempted and completes through 0.21.** The Tier-1 FFI shipped narrow
on purpose; using real libraries (SDL3 measured end-to-end) showed
the narrowness is the friction, and the owner ruled the completion
set: `foreign?` + the `null_foreign` trap, `extern type` named
handles, seamless `str` both directions (reversing the 0.20 "str
never crosses" ruling), C-memory reads, `out` parameters, the full
C scalar set with no arity cap, `extern struct` crossing by pointer,
capture-free `cfunc`, and `extern var`. docs/FFI.md is the contract.
Every 0.20 program remains valid; the amendment adds and never
reshapes. Everything else stays frozen.
Original ratified direction (2026-08-19) follows.

**The constitution (owner, 2026-08-20).** Where a design question has
no Luce-internal answer, the tiebreakers are fixed: **Zig** for
systems and explicitness questions, **Swift** for ARC and memory
questions, **Python** for syntax feel — the best of Swift and Zig
with Python-like syntax. The #24 rulings queue is resolved under this
rule, and future questions default through it before they become
deliberations.

Four owner rulings shape this plan (2026-08-19):

1. **Evidence-driven freeze scope.** The v2 front end starts in
   today's language. Every missing-feature pain point arrives as real
   compiler code, and each candidate (fallible function values,
   list extend, iterator protocol, assert narrowing, …) is ruled on
   with that evidence, one at a time. The already-ratified
   non-capturing lambdas (issue #27) land up front.
2. **Externs are ungated, Zig-style.** Any file may declare a foreign
   function. The safety boundary is *visible*, not *gated*: unsafety
   lives in a dedicated spelling and a scoped-access vocabulary, so it
   is greppable and reviewable — but no manifest permission governs it.
3. **v2 lives in a separate repository.** The differential harness
   pins the corpus and the v1 toolchain by version.
4. **Cancellation/timeouts are designed pre-freeze.** The audit named
   this absence the most likely post-freeze language break; the design
   cycle runs inside Phase 0.

## Phase 0 — truth and rulings (this repo, mostly writing)

The pre-freeze audit's punch list, unchanged in substance:

- Write the float-reduction-order non-promise (issue #21) into the
  numeric docs and `library/math`.
- Rule and spec `try` in subexpressions (issue #11) — it works today
  and is used by shipped specs; the ruling writes down what is
  promised.
- Fix the language spec's construction prose: `docs/LANGUAGE.md` and
  `docs/FILESYSTEM.md` still describe a required `new` keyword the
  compiler no longer has.
- Refresh the stale truth surfaces: the public Status page (56/24 →
  the source-declared pins, 11 → 15 modules, TermUI 0.5, channels /
  selective imports / `luce install` / `std.build` exist), ROADMAP's
  dated audit, CLAUDE.md's pins, NETWORK.md's ABI reference; move the
  landed material out of BUILD.md's plan classification.
- Triage issue #24's decision list and strike landed items from
  #11/#26/#15/#14; close #6.
- Tiny code fixes: the "no lowering for X yet" wording (contradicts
  the total-lowering contract), the zipping cross-check that counts a
  skip as a pass, the worker channel-registry OOM misreport.
- Diagnose the #32 full-gate flake so the freeze certificate is a
  clean run, not a coin flip.
- **Cancellation design cycle** (owner ruling 4): a deadline/cancel
  story that channels, sockets, and `receive_timeout` compose with,
  written as its own design doc and ratified before implementation.

## Phase 1 — ratified language work up front (**already satisfied**)

Non-capturing lambdas (#27), exactly as ratified 2026-08-07 — verified
at head during the Phase 0 night run: the arrow form passes as a
function value, `xs.sort_by((a, b) -> …)` works end to end, and method
references are refused with the ratified teaching diagnostic. The
feature had landed during an earlier run; the issue is closed with the
verification.

## Phase 2 — Tier-1 FFI (design doc first: docs/FFI.md)

The synthesis of the Swift and Zig models, taking declarations from
Zig and safety *visibility* from Swift:

- **Declarations, Zig's way.** A manual `extern` declaration form —
  no header importer, no embedded C compiler. Header translation, if
  ever wanted, is a separate tool emitting `.luc` extern files.
- **Types, Swift's way.** A `std.c` vocabulary aliasing the existing
  exact-width scalars; **opaque foreign handles** (the `LLVMValueRef`
  shape — a token held and passed back, never dereferenced), which is
  the existing `handle` pattern; and buffer access only through
  **scoped closures** (`with_bytes(buffer, func(p): …)`), so a pointer
  exists only inside a lifetime the compiler pinned. No raw pointer as
  an ordinary value in Tier 1.
- **Semantics.** Extern calls are effects: under the effect lock by
  default, with an annotation for blocking/thread-safe calls (the
  socket slots' precedent). Guarantees end at the boundary and the
  docs say so: the census does not count foreign memory, a foreign
  crash is a process crash.
- **Both engines, one dispatch.** The oracle reaches externs through a
  runtime FFI shim (dlopen + libffi in the test-only binary, which
  already links libLLVM); generated code emits direct calls. One
  dispatch semantics, two emission strategies, compared by the
  differential like everything else.
- **Linking.** `build.luc` already compiles C; the dropped `--link`
  option revives so foreign objects join the native link. Inline
  assembly stays out (Swift's answer): a `.s`/`.c` shim assembled by a
  build step and called through `extern` covers everything short of a
  scheduler.
- Blast radius: lexer/parser (`extern` + annotations), semantics, MIR
  (foreign-call instruction, format bump), verifier, runtime shim,
  codegen, oracle, specs (a harness-built test library), docs. The
  host ABI table is untouched — externs are direct calls, not host
  slots.

## Phase 3 — the v2 front end (separate repo; starts after Phase 1)

Runs in parallel with Phase 2 — the front end needs no FFI.
**The v2 compiler is written by the owner.** The toolchain's job here
is the scaffolding around it: the corpus differential, the `.lcm`
seam, the rulings queue — plus *throwaway* probe programs (never
shipped, never the compiler itself) written in current Luce to
discover, ahead of the owner's own work, which language gaps a
compiler-shaped program actually hits.

- Milestone 3a: lexer + parser + AST in Luce, checked against v1 by
  running `luce query diagnostics` (and `luce ir` where it applies)
  over the whole v1 spec corpus and comparing.
- Milestone 3b: semantics + typed lowering.
- Milestone 3c: MIR construction and `.lcm` encoding against the
  frozen format; **acceptance: v2-front + v1-back compiles the corpus
  with artifacts that behave identically** (byte-identical `.lcm` is
  the stretch bar — deterministic printing makes it plausible).
- This phase is the evidence engine: each language pain point the
  compiler hits becomes a ruling request with real code attached
  (owner ruling 1).

## Phase 4 — the v2 back end over LLVM-C (needs Phase 2)

`extern` declarations for the LLVM-C API (opaque handles + scalars +
strings cover it), object emission, the linker driven as `std.build`
already drives `cc`. Acceptance is the classic bootstrap fixpoint:
v2 compiled by v1 compiles v2; that v2 compiles v2 again; the two
v2-built artifacts agree — plus the full-corpus v1-vs-v2 differential,
which becomes the outermost oracle and retires the shared-runtime
blind spot (audit finding #13) by construction.

## Phase 5 — the freeze

The language is whatever v2 needed — no more, no less — and the
self-compile fixpoint plus the v1 differential is the freeze
certificate. ROADMAP §6's lock preconditions run here. v1 retires to
oracle and seed; the bootstrap story is Rust's (a fresh machine builds
v2 with the previous release's binary), with the committed-`.lcm`
snapshot as the purist alternative the frozen format keeps open.

## Phase 6 — after the freeze

The Zig toolchain is dumped gradually, never deleted: it holds the
oracle and seed jobs until the Luce compiler has held both through a
few releases. `libluce_rt` stays a small non-Luce core indefinitely —
Go kept its C runtime for five years; a fully-Luce compiler over a
frozen native runtime is an honest resting point.

## Non-goals

Inline assembly (shims via build steps instead), a C header importer
in the language, Tier-2 raw pointers/struct layout/callbacks (waits
for a post-freeze customer), freestanding/no-runtime profiles, and any
interpreter path for v2 — one engine, everywhere, in both compilers.
