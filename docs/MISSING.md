# What Luce is still missing — the honest inventory

Rewritten 2026-08-02, after the front-end hardening pass, the `std.`
namespace, the LLVM backend, and `docs/FAILURE.md`.  Verified against
the tree, not the docs.  Where a doc and the code disagree, the code
wins and it is said so.

## Scorecard

The **language surface is close to done.**  Ten conceptual stages,
eight folders, four executable specs, stages 1 and 2 marked *Locked*,
and a front end whose diagnostics name the fix rather than the parser's
predicament, and `T?` closed the absence half of the last semantic
hole.  What is designed but unbuilt is errors, and `docs/FAILURE.md`
answers it in full.

The **runtime is not done**, but the wall is down.  Tier 0 held two
items, both properties of what existed rather than missing features,
and **both are now closed**: the C-parity backend is reachable from
`loom run` and from `luce build --emit=exe`, and memory is given back
— object identity was reclaimed first, String bytes and struct field
runs second.  A Luce program can run all day.

---

## Tier 0 — ~~the one wall left~~ — **closed**

### 1. ~~Memory is never given back for values~~ — **closed**

`runtime.Memory` still splits storage in two, but the line moved:
`Memory.objects` now holds everything with a death point — container
contents, the object table, **and every String's bytes and every
struct value's field run** — while `Memory.arena` keeps only what a
program cannot grow without bound (a trap's words, the interpreter's
per-layout struct zero templates, host text on its way into owned
storage).

- ~~Object table rows are never reused~~ — **closed.**  A handle is
  `{index, generation}` and a freed row goes on a free list, so the
  table grows to a program's peak object count rather than to the
  number of objects it ever made, and S9 stays a clean
  `use_after_free` trap because a stale handle's generation is not the
  row's (docs/MEMORY.md).  Measured on a loop making and freeing one
  list per iteration: **281 MB → 21.2 MB at 1M iterations, 593 MB →
  21.3 MB at 4M**, flat where it was linear.
- ~~String bytes go to a run-lifetime arena and are never reclaimed~~
  — **closed.**  A String's bytes and a struct's field run have
  exactly one owner, and any store into something that outlives the
  current statement copies them, so no owner ever holds a view of
  bytes it did not allocate (`docs/STRINGS.md`).  The same churn loop
  — one string built and discarded per iteration, retaining nothing —
  measured on the interpreter: **15.5 / 29.4 / 59.9 / 121.0 MB → 1.8 /
  1.8 / 1.9 / 1.8 MB at 0.5M / 1M / 2M / 4M iterations**, and flat out
  to 16M.  Reference counting, ARC, COW and tracing GC stay
  permanently refused (`docs/MEMORY.md`); what replaced them is the
  language's own claim made literal — *values copy*.

The flagship program was the worked example and is now the proof.
`Editing.splice` (`programs/editor.luc:127`) is
`value[0:cursor] + extra + value[cursor:len(value)]`, and 20,000
keystrokes into a 40 KB file peaked at **1204 MB RSS**.  The same
simulation now peaks at **3.3 MB**, and costs 24 µs a keystroke
instead of 9 — three orders of magnitude inside a 16 ms frame either
way.

What it cost, measured by `bench/compare.sh` on one host: five of the
six benchmarks moved less than 1%, and `bench/strings` went **2.35× C
→ 3.40× C**.  That is allocation, not copying — 800,000 small
allocate-and-free pairs where there used to be unreclaimed bump
allocations and shared views — and **small-string optimisation is the
queued answer**, step 5 of `docs/STRINGS.md`, with the average piece
at 11.7 bytes and every `str(i)` at most 7.

### 2. ~~The engine that reaches C parity cannot be run~~ — **closed**

It can now.  `luce build --emit=exe` writes a standalone binary,
`--emit=library` writes a tagged `.lcn` artifact, and **`loom run`
prefers compiled code for every `.lc` it is handed**, building the
artifact beside the program on first use and falling back to the
interpreter only when the compiled path is genuinely unavailable.
`LOOM_ENGINE` forces either engine.

What that delivers, measured through `loom run` rather than in a
harness: **loops 6995 ms → 92 ms, matmul 5767 ms → 22 ms, strings
931 ms → 57 ms.**  Warm startup is the interpreter's within noise; a
cold run pays LLVM at `-O3` and one `cc` link (80–320 ms) and still
finishes far ahead on anything that computes.

The three decisions, all in `docs/CODEGEN.md`: `cc` links, at build
time only, so the *run* path still invokes nothing; a standalone
binary gets **loom's own host**, terminal included, because a
program's behaviour must not depend on who started it; and every
artifact carries an `abi.Artifact` tag — machine, ABI version, and a
content hash of the program — so a stale or foreign one is refused by
name instead of crashing.  The cache keys on content, never mtime.

What is left of this item is small and named in CODEGEN.md's last
section: no wasm32 emit, nothing sweeps `.lcn` files, and `zig build`
does not pre-warm the bundled programs.

---

## Tier 1 — half the semantic hole is shipped; errors are what is left

**Optionals are done, on both engines.**  `T?`, `none`, narrowing and
`else` run on the interpreter and lower to `{T, i1}` through LLVM, so a
program that says `T?` is compiled like any other — `parse_int` and
`parse_float` answer `Int?`/`Float?` and every bundled program that
calls them runs as native code.  What the lowering cost that
`docs/FAILURE.md` did not predict is one refused shortcut, recorded in
docs/CODEGEN.md: the null handle cannot stand in for absence, because
it already names a value that is *there*.

**Errors (`T!`) are what remains.**  `docs/FAILURE.md` is a complete
design and costs no new MIR instruction and no change to `types.Type`.
None of that half exists yet.  The corpus is unambiguous about the
demand:

- `wordcount.luc:23` — `counts.has(word)` then index: three hash lookups
  on the hit path.
- `wordcount.luc:33` — `var best = ""` as "no answer", indistinguishable
  from an empty key.
- `dice.luc:41` — `if files.write_lines(...)` with **no else**.  A
  silently swallowed write failure, caused directly by Bool-as-error.
  A live bug in the shipped corpus.
- `editor.luc:414`, `wordcount.luc:46` — `file_exists` then `file_read`,
  the TOCTOU pattern FAILURE.md names as the proof.
- 12 `trap(...)` calls in `std/` for conditions a caller might
  reasonably want to handle.

**Now unblocked:** `strings.find` returns `-1` because `Int?` did not
exist.  It does, on both engines, so the sentinel is a wart with
nothing holding it up any more — `strings.luc:20` returns `-1` for an
*argument error*, which is not the same fact as "absent", and
`find_from`'s empty-needle case returns success where `count`'s returns
failure.

---

## Tier 2 — sum types: the absence that keeps bending other designs

No enums, no tagged unions, no `match`.  This is the second-order
blocker: `docs/FAILURE.md` refuses `Result<T, E>` *because* there are no
tagged unions, which is what forced `T!` to be a function attribute.
That answer is probably right, but it is the third design bent around
the same hole.

The corpus pays constantly:

- `editor.luc:342-395` — key handling is **17 string comparisons** with
  no `else`.  A misspelled `"page_dwon"` compiles and silently does
  nothing.
- `editor.luc:187` — `# 1 keyword, 2 type name, 3 builtin, 0 plain.`  An
  enum written as an Int with a comment.
- `editor.luc:157-185` — `is_keyword`/`is_builtin` as **46 `word == "…"`
  comparisons**: a hash set written as a truth table.

**Optionals have shipped, so this is now decidable on evidence.**  A
tagged union built later can subsume `T?` cleanly if that turns out to
be the better factoring; what the corpus does with `T?` from here is
what should settle it.

---

## Tier 3 — what a real program actually hits

Read from `programs/` for awkwardness rather than features.
`editor.luc` is the oldest file in the corpus — it predates std,
f-strings and constants — so it is both the most workaround-dense and
the proof the language moved.

1. **No sets, no constant containers.**  Drives the 46-comparison truth
   tables.  Cheap if scoped to a frozen container.
2. **No character classes in std.**  `is_digit`/`is_alpha` re-derived by
   hand three times.  Trivial — five functions.
3. **No receivers on user structs.**  87 `Struct.func(state, …)` calls;
   the receiver is the first parameter of 10 of 10 functions in
   `struct Text`.  Nine of twelve structs in `programs/` have **no
   fields at all** — namespaces impersonating types.
4. **No multiple returns.**  `calc.luc` declares a struct solely to
   return two Ints, constructed at 8 sites and destructured at 15.
5. **No sort with a comparator.**  `wordcount.luc:58` produces a top-5
   listing by **destroying the map**.  The one place
   no-first-class-functions draws blood.
6. **Host surface gaps:** stdin/`read_line` (calc cannot be a REPL),
   clock, `sleep` (`life.luc` renders ten generations instantly),
   `exit`, `env`, stderr, directory listing, delete/rename, append mode,
   path manipulation.  Each is one builtin plus one wrapper.
7. **No default or named arguments.**  `term_style(fg, bg, bold)` is
   called 16 times; 13 end in the same noise word `false`.
8. **`Bytes` is unconstructible.**  `var b: Bytes` compiles; nothing
   produces one, nothing consumes one, and it is the only thing keeping
   stage 10 from being total.  **Cut it or grow it.**
9. **Integer division spelling.**  `bf.luc:42` writes a decrement as
   `(tape[pointer] + 255) % 256`; `math.luc:91` writes
   `(Int(y) % 2 + 2) % 2`.  Neither `//` nor `rem_euclid` exists.
10. **No visibility.**  std leaks `is_space_byte` and `fold_case`.
    Cheap, and matters before userland libraries exist.
11. **No bitwise operators, no hex literals, no digit separators.**
    Refused by name rather than misread, which is right — but it caps
    what userland can reach.
12. **No codepoint iteration.**  `for c in "abc"` is refused; every
    UTF-8 walk is hand-written, and `editor.luc:51` and `:154` are the
    same function copied across two namespaces.

---

## Resolved since the last edition

- **Character literals — decided against; `ord("(")` folding verified
  working** in expressions and constants.  **But adoption is zero**: a
  grep for `ord` across every `.luc` returns no matches, and 54 bare
  character codes remain across four programs.  std's own
  `is_space_byte` still reads `byte == 32 or byte == 9 or …`.  The
  remaining work is a corpus sweep, not a language change.
- **`Int.min` writable** — the sign folds before the range check.
- **`1e400` refused** — non-finite float literals are rejected.
- **`not a == b` and `a < b < c` are compile errors**, with messages
  naming both readings.
- **Four-space indentation enforced**; **CRLF sources compile**;
  **bidi controls refused everywhere**.
- **The `std.` namespace** — `import math` binds a sibling, `import
  std.math` binds the library, both together is a collision.
- **Trap locations and call traces**; **runaway recursion traps** on
  both engines.
- **Map is O(1)**, open-addressed over insertion-ordered entries.
  **Sort is O(n log n) and stable by guarantee.**
- **Build modes are settled, not pending.**  Luce is always
  `ReleaseSafe`; `--release` is closer to `-fstrip`.
- Also shipped: f-strings, compound assignment, nested place
  assignment, the three std modules, per-stage fuzzing.

---

## Tier 4 — deliberately out of scope, and still right

- **Generics for user code.**  The argument against has strengthened:
  `types.Type` is a closed union with twenty exhaustive switches
  depending on it, and `List(T)` is a monomorphic heap object rather
  than a generic.  `T?` did become a variant of `Type` — one, whose
  payload is a union of its own so `T??` is unrepresentable — and it
  opened no door at all: nothing about it generalizes.  What would pay
  is monomorphized generic *functions*, and that needs first-class
  functions first.
- **Closures — absent, and the cheap answer is not closures.**  The one
  place it draws blood is comparators.  A `sort_by` taking a top-level
  `func` name needs no capture, no lifetime story, and no interaction
  with ownership.  Do that; leave closures out.
- **Iterators.**  What is missing is not a protocol but string
  codepoints — one loop form.
- **Interfaces, inheritance, operator overloading, async, reflection.**
  No.
- **`defer`** — superseded by scope ownership.  Zig removed capturing
  `errdefer` in April 2026; Luce needs neither.

---

## Tier 5 — stage and tooling distance

- **Stage 5 (HIR) is unwritten.**  Desugaring is scattered across
  stages 3 and 4.  The file carries one warning that outranks the
  cleanup: **whole-array operations must survive as single nodes** —
  `std.math`'s BLAS-1 functions are already scalar loops by the time
  MIR exists, and LLVM 22 fuses adjacent elementwise loops under *no*
  configuration of `-O3`.  That is a performance item decided in a
  language stage, and it cannot be taken back.
- **No `luce fmt`, no `luce test`, no LSP, no debugger.**  A `luce test`
  discovering `func test_*():` would be cheap and very Zig.  `fmt` and
  an LSP both want stage 5's faithful tree first — an argument for
  writing it.
- **Docs to correct:** none outstanding.  The interpolation
  contradiction in `LANGUAGE.md` and the "future ReleaseFast" in
  `OWNERSHIP.md` are both fixed.  `STD.md` documents sixteen of the
  eighteen functions in `strings.luc`, and the two it omits —
  `fold_case` and `is_space_byte` — are omitted on purpose because
  they are internals; that they are *reachable* anyway is the
  visibility gap above, not a documentation gap.

---

## Tier 6 — the OS beyond the language

Fabric, persistence, braids and sync, capabilities, the agent,
multi-user — all deferred by design in `docs/V2.md`.

---

## The order to work down

1. ~~**Give String storage a reclaimable lifetime**~~ — **done**; see
   Tier 0.  What follows from it is **small-string optimisation**,
   step 5 of `docs/STRINGS.md`: the design's one real cost is 800,000
   allocations in `bench/strings`, none of them larger than 12 bytes,
   and 22 inline bytes fit in the `Value` that already travels.  It
   costs an `abi.version` bump and a `.lc` `format_version` bump, and
   it is gated on exactly the measurement that now exists.
2. ~~Make the compiled path reachable~~ — **done**; see Tier 0.
3. ~~**`T?`, `none`, narrowing, `else`**~~ — **done on both engines**;
   `parse_int` and `parse_float` answer `Int?`/`Float?`, and a `T?`
   lowers to `{T, i1}`.
4. **The cheap Tier-3 slice:** character classes, a frozen container or
   `Set`, `read_line`, `clock`, `sleep`, `exit`, `env`, stderr,
   directory listing.
5. **Cut `Bytes`** — stage 10 goes total the same day.
6. **`m.get(k) -> V?`**, rewrite `wordcount.luc`, and sweep the corpus
   for `ord("x")` and f-strings.
7. **Errors** — steps 5–7 of FAILURE.md.
8. **Decide receivers, multiple returns, and integer-division
   spelling** — one memo each.
9. **Sum types**, if the `T?` experience says the hole is still there.
10. **Stage 5 (HIR)** — required by `fmt`, by an LSP, and by keeping
    array operations whole.

---

**The honest summary:** the language is nearly complete.  The front end
is in genuinely good shape, and the remaining language work is one
designed feature, one open question, and a short list of library and
host builtins.  The real distance left is in the runtime, and it is
now one thing rather than three: String bytes that are never
returned.
