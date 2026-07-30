# Language audit — July 2026

> **Round 2 addendum lives at the bottom** — after scope ownership
> (OWNERSHIP.md) and file-scope constants landed, the memory model
> was adversarially audited and the codebase organization was
> compared against Zig and CPython practice.  The friction list
> below is the round-1 record; items 1–5 of it are now shipped.

The design target: **Zig's discipline with Python's ease and syntax.**
This audit grades Luce against that target using evidence, not vibes:
the eight programs in `programs/` were written in Luce as it exists,
and every place the language pushed back is recorded here.  The
programs themselves are the exhibits — `wordcount.luc` (Map, file I/O),
`life.luc` (2-D Array, terminal), `calc.luc` (structs, recursion),
`stats.luc`+`mathx.luc` (modules), plus the editor, sort, and the
Brainfuck interpreter.

## Where the vibe lands

**Python's feel, genuinely.**  Indentation blocks, `for x in xs:`,
`elif`, `and/or/not`, slices with open ends (`xs[2:]`), list literals,
`if has(m, key):` — a Python reader follows every program in this tree
without instruction.  Inference keeps annotation noise at Python
levels; annotations appear where a human would want them anyway
(signatures) and almost nowhere else.

**Zig's soul, genuinely.**
- Explicit memory: every allocation is a visible `new` or literal.
  *(Round 1 said "every release a visible free"; round 2's answer is
  better — scope ownership frees everything deterministically, and
  the leak report became an interpreter self-check that never fires.)*
- Checked everything: arithmetic overflows trap, conversions are
  spelled (`Int(x)`), indexes are bounds-checked, use-after-free
  traps with a stable code instead of corrupting.
- No hidden control flow, no hidden allocation, no exceptions.
- A file is a module; structs are namespaces; one flat binary out.
- The verifier ethos paid for itself this week: a real codegen bug
  (registers crossing blocks under short-circuit operands) was caught
  by the IR verifier as a loud internal error, never as wrong output.

## Friction found while writing the programs

Ranked by how often it hurt, with the program that proves it.
*(Update: items 3, 4, and 5 below landed — strings grew
find/contains/starts_with/ends_with/trim/lower/upper/replace/repeat/
split/join, lists and rank-1 arrays grew sort/reverse/find/contains/
fill/clear, and `xs.append(v)` method calls are now the one idiom.
The memory model is under deliberate design in docs/MEMORY.md.)*

1. **No `defer`.**  With explicit `free`, every early `return` after
   an allocation is a leak, so functions contort into single-exit
   shapes (`wordcount.luc` guards args *before* allocating; `median`
   in `mathx.luc` funnels through one exit).  Zig's answer to exactly
   this problem is `defer`, and Luce wants it badly.  **Highest-value
   addition available.**
2. **No file-level constants.**  `editor.luc` fakes a constant table
   with `struct Theme: func keyword() -> Int: return 176` — nine
   functions standing in for nine `let`s.  `calc.luc` compares
   against bare byte numbers (`== 43` meaning `+`).  Top-level
   immutable `let` would delete real boilerplate.
3. **No string utilities.**  `wordcount.luc` hand-rolls word
   tokenization byte by byte; there is no `split`, `find`,
   `contains`, `trim`, `lower`, `starts_with`, or `join`.  Every
   program re-derives these from `byte_at`/`slice`.
4. **No `sort`.**  Insertion sort is now hand-written twice
   (`sort.luc`, `mathx.luc`).  A `sort(xs)` builtin (or a shippable
   std module, now that modules exist) ends that.
5. **Free functions where Python fingers expect methods.**
   `append(xs, v)` instead of `xs.append(v)` is the single biggest
   "this isn't quite Python" moment.  Method-call *sugar* for the
   builtin collections (rewriting `xs.append(v)` to `append(xs, v)`
   in the compiler, no semantic change) would buy most of the feel
   for little cost.
6. **Map iteration yields keys only.**  `wordcount.luc` pays a lookup
   inside the loop (`counts[word]`) that `for word, count in counts:`
   would erase — and with today's linear-scan Map, that lookup is
   O(n) inside O(n).
7. **No character literals.**  `byte_at(...) == 40` with a comment
   saying "(" is calc.luc's whole parser.  Any spelling — `'('` or
   compile-time-folded `ord("(")` — fixes it.
8. **No line input.**  `key_read` is raw-mode; there is no
   `read_line()` host builtin, so `calc` takes its expression as an
   argument instead of being a REPL.

## Neither Zig nor Python (deliberate, but worth owning)

- **`new`** is Java's word, not Zig's or Python's.  It stays because
  it delivers a Zig value (allocations visible at the call site) at
  Python-keyword weight — but it should stay a *decision*, not an
  accident.
- **Integer `/` truncates** (Zig) where Python floors and returns
  float.  `%` follows the dividend's sign (Zig), where Python floors
  — `bf.luc` dodges with `(x + 255) % 256`.  If Python fingers are
  the priority, consider: `/` on Ints becomes a compile error
  ("conversions are explicit" already points this way), `//` is
  integer division.  Flagged as an open question, not changed.
- **`Array(Int, _, _)` in types vs `new Array(Int, 5, 5)` at
  creation** — the wildcard asymmetry is documented and consistent,
  but it is the one piece of type syntax with no Python or Zig
  precedent.
- **Struct functions call fully qualified even at home**
  (`Words.classify` inside `struct Words`) — namespacing noise Python
  wouldn't have and Zig avoids with `@This()`.

## Open design questions (biggest first)

1. **Error handling.**  Today: traps (fatal) plus Bool returns
   (`file_write`).  Zig's identity is `!T` error unions and `try`.
   Before the std library grows, decide whether Luce gets a
   recoverable-error story or stays trap-only-with-guards
   (`file_exists` before `file_read`).  This is the largest
   Zig-alignment gap in the language.
2. **Methods.**  Sugar only (recommended above), real receivers, or
   never — decide once, before userland grows bigger.
3. **Map performance.**  Linear entries are honest and
   insertion-ordered; a hash index behind the same semantics is a
   pure implementation upgrade when a program earns it.

## Recommended next moves, in order

1. ~~`defer`~~ — superseded: scope ownership (OWNERSHIP.md) removed
   the need; `free` survives only as deliberate early release.
2. ~~Top-level `let` constants~~ — shipped (Phase 2).
3. ~~String utilities + `sort`~~ — shipped as methods.
4. ~~Method-call sugar for builtins~~ — shipped.
5. `for key, value in map:`.
6. Character literals.
7. `read_line()` host builtin.

Everything above is additive; nothing written so far would break.

---

# Audit round 2 — 30 July 2026

Two audits ran after ownership (Phase 1) and file-scope constants
(Phase 2) landed: an **adversarial memory audit** (write programs
that leak, dangle, or double-free; every suspicion run against the
real toolchain) and an **organization review** against Zig-compiler
and CPython practice.

## Memory audit: found and fixed

The core machinery — statement temporaries, scope releases,
early-exit unwinding, frame serials under recursion, container
adoption, return moves, deep copies — **held against everything
thrown at it**.  Five real holes were found at the edges, all fixed
the same day, each with a regression test built from the audit's own
reproducing program (`src/luce/ownership_spec.zig`, "audit:" tests):

1. `Array.fill` with object elements sat outside the ownership
   machinery entirely — the one confirmed leak path, plus a dangling
   reference from a verb-free program.  Fix: `fill` on
   object-carrying elements is a compile error (one value cannot own
   every slot; store per slot).
2. List literals skipped the S21 keeping rule, so `[hits]` let a
   *borrowing* callee adopt — and then free — the caller's object.
   Fix: literal elements are a container door like any other.
3. The S30 give/free loop guard missed `while` conditions.  Fix: the
   loop frame is pushed before the condition lowers.
4. `len(give xs)` and friends compiled — a give with no owner to
   receive it silently became an early free.  Fix: give is refused in
   pure borrow positions (builtin arguments, non-adopting method
   arguments, operator operands).
5. give/free verified only "not container-owned", so an alias could
   move ownership and a stale `free(xs)` still fired.  Fix: verbs on
   owned names carry their binding and the runtime verifies the name
   still owns the object (`not_owned` trap).  Bonus: reassigning a
   name while a `for` iterates it is now a compile error instead of a
   deterministic use-after-free.

Accepted behaviors, recorded deliberately: `x = f(give x)` is
unwritable (S29's blunt poisoning — use a fresh name); the i64
minimum cannot be written as a literal (parity with runtime
literals); `give` through an alias may hand ownership to a new
binding silently (memory-safe and coherent; the dangerous stale-free
half now traps).

## Organization review: verdict

The stage layout (lexer → parser → analyzer → IR → interpreter →
module format) matches the Zig compiler's decomposition at healthy
sizes, the host boundary is stricter than CPython ever achieved, and
the exhaustive intrinsic enum makes analyzer/interpreter drift a
compile error.  Acted on: one shared file loader for both executables
(`src/apps/files.zig`), named AST/IR payload structs replacing ~35
`anytype` signatures, the pending-trap error flow in the interpreter
(the ceval pattern; ~150 lines of resolve/host boilerplate gone),
direct verifier tests in `ir.zig`, the ownership spec consolidated
into one file, this guide refresh (`docs/CODING_GUIDE.md` replaces
the v1 guide as authority).

Deliberately deferred: making `sequenceMethod`/`objectMethod` fully
table-driven like `stringMethod` (worth doing when the method set
next grows), and splitting `analyzer.zig` at its
Analyzer/FunctionBuilder seam (the file is ~3.8k lines; Zig's Sema is
38k — split when it earns it).

## Standing open questions (unchanged in substance)

1. **Error handling + optionals** — Phase 3, deliberately awaiting a
   design conversation (`T?` and the recoverable-error story are one
   decision).
2. **Map performance** — linear entries stay honest until a program
   earns the hash index.
3. `for key, value in map:`, character literals, `read_line()` —
   still the next ergonomic wins, still additive.
