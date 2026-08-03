# What Luce is still missing — the honest inventory

Rewritten 2026-08-02, after the front-end hardening pass, the `std.`
namespace, the LLVM backend, and `docs/FAILURE.md`.  Verified against
the tree, not the docs.  Where a doc and the code disagree, the code
wins and it is said so.

## Scorecard

The **language surface is close to done.**  Ten conceptual stages,
eight folders, four executable specs, stages 1 and 2 marked *Locked*,
and a front end whose diagnostics name the fix rather than the parser's
predicament.  The one designed-but-unbuilt semantic hole is optionals
and errors, and `docs/FAILURE.md` answers it in full.

The **runtime is not done**, and that is where the walls now are.  Both
Tier 0 items are properties of what exists rather than missing
features, and both outrank every feature below them.

---

## Tier 0 — the two walls a large program hits first

### 1. Memory is never given back for values or for object identity

`runtime.Memory` splits storage in two (`runtime/heap.zig:41-62`).
Object *storage* goes to a freeing allocator — that is the 410 MB → 60 MB
churn fix, and it is real.  But:

- **String bytes go to a run-lifetime arena and are never reclaimed.**
  Measured on a loop building and discarding a string per iteration,
  retaining nothing: **28 / 36 / 54 / 90 MB RSS at 0.5M / 1M / 2M / 4M
  iterations** — dead linear, ~18 bytes per iteration, forever.
- **Object table rows are never reused** (`heap.zig:238-241`).  That is
  a deliberate trade for making S9 a clean `use_after_free` trap, and
  it costs **~100 bytes retained per object ever created**.

The flagship program is the worked example.  `Editing.splice`
(`programs/editor.luc:127`) is
`value[0:cursor] + extra + value[cursor:len(value)]`; the two
concatenations each copy the whole buffer into the arena.  Simulating
**20,000 keystrokes into a 40 KB file peaks at 976 MB RSS.**  The editor
is not usable for a long session on a real file, and neither is any
program with a main loop.

This is the difference between a program having a memory *footprint*
and having a memory *lifetime*.

**Cost:** a design decision, not a bug fix.  Options: a scoped arena for
Strings (statement temporaries are already unnamed and statement-scoped,
which S3 licenses), refcounted immutable string storage, or a free list
of table rows with a generation counter in the handle — which keeps S9's
clean trap while making rows reusable.  The last is small and should
probably come first.

### 2. The engine that reaches C parity cannot be run

`docs/CODEGEN.md` measures the LLVM path at **0.97–1.06× of C** on
matmul, arrays, stats, loops and math, and stage 10 lowers everything a
script can say.

But `luce build --backend=llvm` emits **only a relocatable object**.
There is no executable emit, no shared-library emit, and loom cannot
load one.  `luce` has three commands — `build`, `check`, `ir` — and no
`run`.  Every `.lc` anyone executes goes through the interpreter, which
measures against the C twins at **loops 30.5×, matmul 60.1×, strings
7.3×**.

So "parity with C" is achieved in a test harness and delivered to
nobody.  `08_llvm/test.zig` already links with `cc -shared` and
`dlopen`s the result — the missing piece is a supported emit mode plus a
loader, not new codegen.

---

## Tier 1 — the one semantic hole, fully designed, zero lines shipped

**Optionals (`T?`) and errors (`T!`).**  `docs/FAILURE.md` is a complete
design and costs no new MIR instruction and no change to `types.Type`.
None of it exists yet.  The corpus is unambiguous about the demand:

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

**Deliberately deferred:** `strings.find` returns `-1` until `Int?`
exists.  Note the wart while it lasts — `strings.luc:20` returns `-1`
for an *argument error*, which is not the same fact as "absent", and
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

**Decide after optionals ship, not before.**  A tagged union built later
can subsume `T?` cleanly if that turns out to be the better factoring.

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
  `types.Type` is a closed eight-variant union with twenty exhaustive
  switches depending on it, `List(T)` is a monomorphic heap object
  rather than a generic, and `T?` is *not* being special-cased into
  `Type` at all.  Nothing about optionals opens this door.  What would
  pay is monomorphized generic *functions*, and that needs first-class
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
- **Docs to correct:** `LANGUAGE.md` lists string interpolation as
  deliberately absent, 200 lines after documenting f-strings.
  `OWNERSHIP.md` still says "a future ReleaseFast"; `MODES.md` refuses
  one.  `STD.md` lists 14 of 17 string functions.

---

## Tier 6 — the OS beyond the language

Fabric, persistence, braids and sync, capabilities, the agent,
multi-user — all deferred by design in `docs/V2.md`.

---

## The order to work down

1. **Reuse object-table rows and give String storage a reclaimable
   lifetime.**  Nothing else matters if a program cannot run for an
   hour.
2. **Make the compiled path reachable** — executable emit, or a loader
   in loom.  C parity already exists; it is not delivered.
3. **`T?`, `none`, narrowing, `else`** — step 1 of FAILURE.md's order,
   with `parse_int`/`parse_float` as day-one users.
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
host builtins.  The real distance left is in the runtime — memory that
is never returned, and a C-parity backend nobody can run.
