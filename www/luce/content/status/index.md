# Where Luce stands

Luce is a real language with a real compiler, a real runtime, a real
terminal and a real editor written in itself. It is also early, and
this page is what that means, written from the repository's own
inventory rather than from hope.

Nothing here is rounded up. Where the repository's own notes say a
prediction was too optimistic, this page says so too.

## The short version

**The shipped language core is locked.** Ten conceptual pipeline
stages, a registered executable specification, and a front end whose
diagnostics mostly name the fix rather than the parser's predicament.
Optionals closed absence and errors closed failure. Typed channels are
the approved next design-and-implementation run, not a feature silently
counted as shipped or a surface already fully ratified.

One ownership diagnostic remains deliberately below that standard:
retaining calls, constructions and literals are refused correctly, but
an early bare owner can be told to add `give` even when that edit would
poison a later occurrence in the same operand batch. This is advice
precision, not semantic acceptance.

**The runtime is not done, but the wall is down.** The two items that
blocked real programs are both closed: a `.lc` **is** machine code,
with six of the nine current benchmarks at C parity, whether `loom run`
opens it or a shell runs an `--emit=exe` binary, and memory is genuinely
given back for owner trees — object identity first, then string bytes
and struct field runs. Retaining stores refuse a visible ownership cycle
statically and trap an alias-hidden one before mutation.

**What is left is a short list of library questions and tracked runtime
hardening, the typed-channel design-and-implementation run, a drafted but
unscheduled union design, and three measured performance gaps.**

## What works

| | |
|---|---|
| Static typing with inference; `long` widens to `double`, nothing narrows | shipped |
| Checked arithmetic, bounds checks, UTF-8 boundary checks, in every mode | shipped |
| Scope ownership: `give`, `copy`, `free`, 46 ratified situations | shipped |
| `T?`, `none`, narrowing, `else` | shipped |
| `T!`, `try`, `catch`, `error` | shipped |
| f-strings, compound assignment, nested place assignment | shipped |
| File-scope `const`: folded values and flat immutable program-root containers | shipped |
| Runtime and constant `{key: value}` map literals; empty `{}` refused | shipped |
| Modules, and a reserved `std.` namespace | shipped |
| Function values and capture-free expression lambdas | shipped |
| Implied-self methods and `static` namespace functions | shipped |
| Multiple returns into new or existing bindings | shipped |
| Structured workers with owned `task` joins | shipped |
| Eight standard modules: `math`, `files`, `strings`, `lists`, `paths`, `os`, `zip`, `json` | shipped |
| The bit set: `&` `\|` `^` `~` `<<` `>>` at Go's precedence, hex and binary literals, `_` digit separators | shipped |
| Visibility: public until a declaration says `private` | shipped |
| Enums at a chosen integer width, and `match` with every member named | shipped |
| LLVM backend: a `.lc` **is** machine code, `--emit=exe` standalone binaries | shipped |
| Trap locations and call traces in debug builds | shipped |
| Two build modes that differ only in what a trap can say | shipped |
| map lookups O(1); sort O(n log n) and stable by guarantee | shipped |

The compiler-internal serialized module is format **34**. Program-root
containers moved it to 33 by adding a pool, instruction and trap code;
the later `ownership_cycle` trap moved it once more. The published host
ABI remains **13** because neither change added a host slot.

## What is measured

Against C twins at `-O3 -march=native`, on one host, on the
floor-subtracted `compute` column: **0.78× to 1.06× on six of the nine
benchmarks** — loops, math, arrays, both matrix multiplies and
statistics. Three are behind, for three different reasons: **2.67× on
strings**, which is allocation-bound rather than
code-generation-bound; **2.60× on lists**, which is `append` and
nothing else, a list's length living in the object's row where C's
count lives in a register; and **8.66× on the 32-bit array
reduction**, which is the price of checking every integer add — the
loop cannot be reassociated, so it cannot be vectorized.
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
  opposite of what Luce is aiming at; one source-reachable dynamic
  lifetime check covers the alias that outlives its owner.
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
  door at all: nothing about it generalises. Function values now exist,
  but user-written monomorphised generic functions would still add a
  new surface and a specialization model. `std.lists.sort_by` uses one
  compiler-owned closed specialization instead.
- **Closures.** Capture-free lambdas and function values shipped, and
  `std.lists.sort_by` closed the comparator wound without an
  environment, lifetime story or ownership rule for captured state.
  Behavior plus state remains a struct with a method.

## Approved next, and drafted later

**Typed channels between workers are the approved next
design-and-implementation run.** Workers and owned `task` joins shipped
first. `docs/THREADS.md` D12 ratifies typed pipes and the direction in
which `send(give x)` moves ownership between worker runtimes. It does
not yet ratify endpoint construction, capacity and back-pressure,
receive and close behavior, or the failure surface; those belong to
that next run, built on the existing two-runtime transfer and worker
machinery.

**Tagged unions — a member with a payload.** Enums shipped, and with
them [`match`](/tour/enums/): a set of names at one integer width,
dispatch that refuses to compile when a member has no arm, and
`Method(n)` answering `Method?` for the number that arrived from a
file. What a member still cannot carry is a *value*. The tagged
direction is ratified and the full design is drafted with three held
questions, but it is not scheduled. It is also the reason a
`Result`-style error type was refused in favour of `T!` as a function
attribute.

The half that shipped was decided on the corpus, and the corpus has
spent it. `std.zip` reads a compression method and a DEFLATE block
type through enums rather than through `== 8` and an `elif` chain
whose last arm existed to say "unknown". And `editor.luc` — the file
whose three warts argued for the feature — has had all three taken
out:

- keys were handled with **15 string comparisons in one `elif` chain
  and no final `else`**, so a misspelled `"page_dwon"` compiled and
  silently did nothing. There is now an `enum Intent` with sixteen
  members; the host's key names are translated to it **once**, at the
  edge, with the unbound case named `ignored` rather than fallen
  through, and the `match` that dispatches has an arm for every
  member. Past that one function the editor never compares a string
  to decide what to do.
- `# 1 keyword, 2 type name, 3 builtin, 0 plain` — an enum written as
  a `long` with a comment — is `enum Word`, and the `elif` chain over
  the numbers is a `match` with four arms and no `else`.
- `is_keyword` and `is_builtin` as **46 `word == "…"` comparisons** —
  a hash set written as a truth table — are two immutable constant
  maps. Membership is now the direct hash lookup the intent asked for;
  the remaining wart is only that `map(string, bool)` carries an
  unused value where a future `set(string)` would not.

The word lists were eight language generations out of date while they
were comparisons: ten keywords and twenty-one builtins the language
had gained were missing, and two names it does not have as free
builtins were still there. The editor maps are current but still
mirror those tables by hand. The VS Code grammar takes the stronger
route: it is generated directly from the compiler's tables.

## The short list of what a real program hits

Read out of `programs/` for awkwardness rather than for features.
`editor.luc` used to be the oldest file in the corpus — written
before enums, `match`, visibility, the standard library, f-strings
and constants — and was for a long time both the most workaround-dense
program and the proof that the language moved. It has now been
rewritten onto everything it predated, which leaves one representational
wart standing: item 1.

1. **No sets.** Constant containers shipped, and the editor's former
   46-comparison truth tables are now immutable `map(string, bool)`
   literals with constant-time membership and duplicate-key checking.
   A future `set(string)` would express the same table without an
   unused `bool`; nothing is blocked on it.
2. **No character classes in the library.** `is_digit`/`is_alpha`
   re-derived by hand three times. Five functions would fix it.
3. ~~**No receivers on user structs.**~~ **Shipped.** Every plain
   member has implied `self`; a namespace member says `static func`.
   Receiver writing is inferred transitively and aliases one bare
   owning `var` in place, while reads accept lets and temporaries and
   borrowed object contents keep their old mutation rule. The 88
   namespaced calls turned out **not**
   to be 88 waiting method calls — they are calls on folders, and not
   one function in the corpus took its own struct first. What the
   feature bought was the restructuring it permits.
4. ~~**No multiple returns.**~~ **Shipped.** `-> (A, B)`,
   `return a, b`, `let low, high = f()`, and `low, high = f()` for
   existing mutable bare names. The assignment prepares one whole
   answer before replacing any name. The struct that existed solely
   to carry a return — constructed at 8 sites and taken apart by 25
   field reads, not the 15 this page used to claim — is deleted.
5. ~~**No sort with a comparator.**~~ **Shipped.** After `import
   std.lists`, `xs.sort_by(before)` takes a named function or a
   capture-free lambda. The in-place sort is stable, O(n log n), and
   works for every list element type.
6. **Host surface gaps.** Mostly closed: the clock, `sleep`,
   environment access, stderr, reading a line, directory listing,
   delete/rename and append mode all shipped with host ABI version 8,
   and `exit` and path manipulation have since shipped too — the
   latter as [`std.paths`](/std/paths/), which is where it always
   belonged. What is still absent is a wall clock and a calendar,
   setting an environment variable, and reading the whole environment.
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
11. ~~**No bitwise operators, no hex literals, no digit separators.**~~
    **Shipped.** `& | ^ ~ << >>` on the integers at Go's precedence
    (so `flags & mask != 0` reads correctly), shifts that move bits
    with the count as the one thing that traps, the five compound
    forms, and the literals: `0xFF`, `0b1010`, `1_000_000`. Octal
    stays refused by name
    ([the operator rules](/ref/lexical/#operators-and-punctuation)).
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

There **is** a VS Code syntax definition in the repository, and it
cannot go stale: it is *generated* from the compiler's own keyword,
symbol, builtin and method tables and pinned byte-for-byte by a test,
so a language change that forgot the grammar fails the build rather
than shipping a highlighter that disagrees with the compiler.

## The order the work goes in

1. Typed channels — the approved D12 design-and-implementation follow-on
   to workers; its full surface is not ratified yet.
2. The cheap library slice: character classes, `m.get(k) -> V?`, and
   decide whether a dedicated `set` earns its surface.
3. Cross-compilation and sharing one runtime between artifacts.
4. Tagged unions only when the drafted design is scheduled.
5. The faithful syntax tree, which a formatter and a language server
   both need.

## The honest summary

The shipped core is locked and the front end is in genuinely good
shape. Typed channels are the approved next design-and-implementation
run; tagged unions are drafted but unscheduled, and a short list of
library questions remains. The channel-independent runtime prerequisites
are closed: worker registries synchronize their own lifetime, every file
callback is effect-serialized, a failed file-resource allocation closes
the raw handle it acquired, and partial cross-runtime copies roll back.
Retaining stores also preserve an acyclic owner tree. Separately, three
benchmarks are behind for the three stated reasons above.

If you are looking for a language to build production systems on
today, this is not that. If you are interested in a small, fast,
statically typed language that reclaims memory without a collector and
without reference counting, and that says out loud what it cannot yet
do — it is right here, and every claim on this site was checked
against the compiler when the page was built.
