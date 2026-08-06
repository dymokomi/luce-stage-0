# Where Luce stands

Luce is a real language with a real compiler, a real runtime, a real
terminal and a real editor written in itself. It is also early, and
this page is what that means, written from the repository's own
inventory rather than from hope.

Nothing here is rounded up. Where the repository's own notes say a
prediction was too optimistic, this page says so too.

## The short version

**The language surface is done as designed.** Ten conceptual pipeline
stages, eight executable specifications, and a front end whose
diagnostics name the fix rather than the parser's predicament.
Optionals closed the absence half of the last semantic hole and errors
closed the failure half; nothing that was designed is now unbuilt.

**The runtime is not done, but the wall is down.** The two items that
blocked real programs are both closed: a `.lc` **is** machine code at
C parity, whether `loom run` opens it or a shell runs an `--emit=exe`
binary, and memory is genuinely given back — object identity first,
then string bytes and struct field runs. A Luce program can run all
day.

**What is left is a short list of library and host builtins, one open
language question, and one benchmark row.**

## What works

| | |
|---|---|
| Static typing with inference; `long` widens to `double`, nothing narrows | shipped |
| Checked arithmetic, bounds checks, UTF-8 boundary checks, in every mode | shipped |
| Scope ownership: `give`, `copy`, `free`, 43 ratified situations | shipped |
| `T?`, `none`, narrowing, `else` | shipped |
| `T!`, `try`, `catch`, `error` | shipped |
| f-strings, compound assignment, nested place assignment | shipped |
| File-scope constants, folded and inlined | shipped |
| Modules, and a reserved `std.` namespace | shipped |
| Four standard modules: `math`, `strings`, `files`, `paths` | shipped |
| Visibility: public until a declaration says `private` | shipped |
| LLVM backend: a `.lc` **is** machine code, `--emit=exe` standalone binaries | shipped |
| Trap locations and call traces in debug builds | shipped |
| Two build modes that differ only in what a trap can say | shipped |
| map lookups O(1); sort O(n log n) and stable by guarantee | shipped |

## What is measured

Against C twins at `-O3 -march=native`, on one host, on the
floor-subtracted `compute` column: **0.77× to 1.06× on loops, math,
arrays, matrix multiply and statistics**, and **2.73× on strings**.
That last row is the one genuinely behind, and it is allocation-bound
rather than code-generation-bound.
[The table and its caveats](/guide/performance/).

Memory, on a churn loop that retains nothing: **flat**, where it used
to grow linearly to 121 MB. What is left on the compiled path is
20.4 MB of allocator working set for a hot allocate-and-free loop,
and it does not move with the iteration count. The editor simulation:
**1204 MB to 3.3 MB** peak.
[How, and what it cost](/guide/memory/).

Small-string optimisation was predicted to remove "essentially all" of
the cost of giving string bytes an owner. It removed roughly three
quarters. The repository records that the prediction was too strong.

## Deliberately absent, permanently

These are decisions with reasons written down, not gaps.

- **Tuples.** A function may answer more than one value, but the shape
  it answers them in is not a type: it cannot annotate anything, nest,
  or be written as an expression. An anonymous structural product type
  would be the first structural type in a language with no generics
  and no sum types, and every one of those asks whether it nests,
  whether a container holds it, and whether it compares. A pair that
  travels together is a struct.
- **Garbage collection and reference counting**, at every layer, in
  the language and in the runtime alike. Also copy-on-write and
  automatic reference counting. Scope ownership is the model.
- **Shared ownership** (`share`) and **weak references**. A program
  that needs genuinely shared ownership restructures, or uses indices
  into a container it owns.
- **Static borrow checking.** Lifetimes and aliasing rules are the
  opposite of what Luce is aiming at; two dynamic checks cover what
  the static rules cannot see.
- **`errdefer` and error return traces.** Both refused, with reasons —
  the one bit `errdefer` encodes is already a parameter of the
  unwinder, and a trace would charge the success path.
- **Exceptions.** Traps are final.
- **Implicit narrowing, shadowing, truthiness, a ternary operator.**
- **Interfaces, inheritance, operator overloading, async, reflection.**
- **`defer`** for memory. It may return for host cleanup, as a
  separate decision.
- **Generics for user code.** The type union is closed with twenty
  exhaustive switches over it, and `list(T)` is a monomorphic heap
  object rather than a generic. `T?` became a variant and opened no
  door at all: nothing about it generalises. What would pay is
  monomorphised generic *functions*, and that needs first-class
  functions first.
- **Closures.** The one place their absence draws blood is
  comparators, and the cheap answer is a `sort_by` taking a top-level
  function name — no capture, no lifetime story, no interaction with
  ownership. That, not closures.

## Absent and not decided

**Sum types — no enums, no tagged unions, no `match`.** This is the
open language question, and it is a second-order blocker: a
`Result`-style error type was refused *because* there are no tagged
unions, which is what forced `T!` to be a function attribute instead.
That answer turned out better than "probably right", but it is still
the third design bent around the same hole.

The corpus pays for it constantly, and the counts are real:

- `editor.luc` handles keys with **15 string comparisons in one
  `elif` chain and no final `else`**. A misspelled `"page_dwon"`
  compiles and silently does nothing.
- `editor.luc` writes `# 1 keyword, 2 type name, 3 builtin, 0 plain` —
  an enum written as an `long` with a comment.
- `editor.luc` implements `is_keyword` and `is_builtin` as **46
  `word == "…"` comparisons**: a hash set written as a truth table.

Now that optionals have shipped, this is decidable on evidence rather
than on argument. What the corpus does with `T?` from here is what
should settle it.

## The short list of what a real program hits

Read out of `programs/` for awkwardness rather than for features.
`editor.luc` is the oldest file in the corpus — it predates the
standard library, f-strings and constants — so it is both the most
workaround-dense and the proof that the language moved.

1. **No sets and no constant containers.** Drives the 46-comparison
   truth tables.
2. **No character classes in the library.** `is_digit`/`is_alpha`
   re-derived by hand three times. Five functions would fix it.
3. ~~**No receivers on user structs.**~~ **Shipped.** A function is a
   method exactly when its first parameter is `self`; `var self`
   writes the receiver back. The 88 namespaced calls turned out **not**
   to be 88 waiting method calls — they are calls on folders, and not
   one function in the corpus took its own struct first. What the
   feature bought was the restructuring it permits.
4. ~~**No multiple returns.**~~ **Shipped.** `-> (A, B)`,
   `return a, b`, `let low, high = f()`. The struct that existed
   solely to carry a return — constructed at 8 sites and taken apart
   by 25 field reads, not the 15 this page used to claim — is
   deleted.
5. **No sort with a comparator.** `wordcount.luc` produces a top-five
   listing by **destroying the map**. The one place the absence of
   first-class functions draws blood.
6. **Host surface gaps.** Mostly closed: the clock, `sleep`,
   environment access, stderr, reading a line, directory listing,
   delete/rename and append mode all shipped with host ABI version 8.
   What is still absent is `exit` and path manipulation.
7. ~~**No default or named arguments.**~~ Closed: every parameter has
   a name a call site may write, defaults are trailing compile-time
   constants, struct fields take the same clause, and the builtin
   table carries `term_style(fg, bg = -1, bold = false)` — the calls
   that ended in the same noise word `false` now write the argument
   that varies and nothing else.
8. ~~**`Bytes` is unconstructible.**~~ Cut. Nothing produced one and
   nothing consumed one, and it was one of the two things keeping the
   backend from lowering everything a program can say. The backend is
   now total. A real `Bytes` would be designed fresh.
9. ~~**No integer-division spelling.**~~ **Shipped.** `//` is floor
   division, `%` is the modulus that pairs with it, and `/` is real
   division; the decrement that was written
   `(tape[pointer] + 255) % 256` is `(tape[pointer] - 1) % 256`, the
   spelling its author meant.
10. ~~**No visibility.**~~ **Shipped.** A declaration is public unless
    it says `private` — per declaration, or as an indented region
    inside a struct — and touching a marked name from outside its
    file is `luce.sema.private`, answered as *private*, never as
    *unknown*. The two leaked string helpers are marked, `Rng.state`
    is too, and `math.rng(seed)` is the constructor the idiom that
    reached through it always wanted
    ([the chapter](/tour/visibility/),
    [the rules](/ref/modules/#visibility)).
11. **No bitwise operators, no hex literals, no digit separators.**
    Refused by name rather than misread, which is right — but it caps
    what userland can reach.
12. **No codepoint iteration.** `for c in "abc"` is refused; every
    UTF-8 walk is hand-written, and the same function is copied across
    two namespaces in one file.
13. **`m.get(k) -> V?` does not exist**, so `has` then index is three
    hash lookups on the hit path. The counting case no longer needs
    it — `counts[word] += 1` defines a missing key at the value
    type's zero — but a lookup that must tell a stored `0` from an
    absent one still has nothing better than `has`.
14. **`strings.find` returns `-1`** because `long?` did not exist when
    it was written. It does now, so the sentinel is a
    wart with nothing holding it up — and it also returns `-1` for an
    *argument* error, which is not the same fact as "absent".

## Tooling

There is no `luce fmt`, no `luce test`, no language server and no
debugger. A `luce test` that discovered `func test_*():` would be
cheap and very Zig; a formatter and a language server both want a
faithful syntax tree that is not written yet.

There **is** a VS Code syntax definition in the repository, and it is
stale — it still lists builtins from a removed era.

## The order the work goes in

1. The cheap slice: character classes, a frozen container or a `Set`,
   `exit`, and path manipulation.
2. `m.get(k) -> V?`, and a corpus sweep.
3. ~~Decide receivers and multiple returns~~ — shipped; the
   integer-division spelling is decided too.
4. Sum types, if the experience with `T?` says the hole is still
   there.
5. The faithful syntax tree, which a formatter and a language server
   both need.

## The honest summary

The language is complete as designed. The front end is in genuinely
good shape, and the remaining language work is one open question and a
short list of library and host builtins. The runtime's outstanding
item is not correctness but speed, in one benchmark row.

If you are looking for a language to build production systems on
today, this is not that. If you are interested in a small, fast,
statically typed language that reclaims memory without a collector and
without reference counting, and that says out loud what it cannot yet
do — it is right here, and every claim on this site was checked
against the compiler when the page was built.
