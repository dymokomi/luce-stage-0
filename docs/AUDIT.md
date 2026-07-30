# Language audit — July 2026

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
- Explicit memory: every allocation is a visible `new` or literal,
  every release a visible `free`, and loom's leak report after every
  run is the moral equivalent of `std.testing.allocator`.
- Checked everything: arithmetic overflows trap, conversions are
  spelled (`Int(x)`), indexes are bounds-checked, use-after-free
  traps with a stable code instead of corrupting.
- No hidden control flow, no hidden allocation, no exceptions.
- A file is a module; structs are namespaces; one flat binary out.
- The verifier ethos paid for itself this week: a real codegen bug
  (registers crossing blocks under short-circuit operands) was caught
  by the IR verifier as a loud internal error, never as wrong output.

## Friction found while writing the programs

Ranked by how often it hurt, with the program that proves it:

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

1. `defer` (pairs with `free`; also cleans up terminal/file patterns).
2. Top-level `let` constants.
3. String utilities + `sort` (as builtins now, or as the first
   shipped std module — modules exist, `import std` is one design
   decision away).
4. Method-call sugar for builtins.
5. `for key, value in map:`.
6. Character literals.
7. `read_line()` host builtin.

Everything above is additive; nothing written so far would break.
