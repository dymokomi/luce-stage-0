# What Luce was missing, and no longer is — the closed record

**This file exists so that `docs/MISSING.md` can be read as a to-do
list rather than as a history.**  That document is the honest gap list
and the closest thing this project has to a work queue; by 2026-08-12
it was 1,221 lines with sixty-one strikethrough markers in it, whole
tiers closed at the top, and closed items scattered through the open
ones.  A reader looking for what is left had to read what was done
first.  So the done work moved here, and MISSING.md kept only the
gaps.

**What an entry here is:** what was missing, when and how it closed,
and where the detail lives — the decision memo's *As built* section
and, where it helps, the commit.  Two kinds of entry, deliberately:

* Where MISSING.md's closed prose said something **no other document
  says** — the argument for why a thing was hard, a measurement taken
  against a tree that no longer exists, a rejected alternative — the
  prose moved **verbatim**.  Those measurements are the record and
  cannot be retaken.
* Where the closed entry only restated a memo's *As built* — unions,
  function values, packages, constant containers, `self`, enums — the
  entry is **one line and a pointer**.  Duplicating a memo is how two
  documents start disagreeing.

**This is a record, not a reference.**  Like every decision record in
`docs/`, it is written in the present tense about the world it
describes and is not maintained against the tree afterwards.  Where it
disagrees with a living document, the living document wins.  Line and
file references are as they were when the entry closed and are not
re-derived; MISSING.md re-derives its own.

Ordered chronologically, oldest first.

---

## 2026-08-02 — Tier 0, item 1: memory is never given back for values

**What was missing.** The runtime split storage in two and only one
half had a death point.  A program that made and discarded values ran
until the machine ran out.

**How it closed.** `runtime.Memory` still splits storage in two, but
the line moved: `Memory.objects` now holds everything with a death
point — container contents, the object table, **and every string's
bytes and every struct value's field run** — while `Memory.arena`
keeps only what a program cannot grow without bound (a trap's words,
the per-layout struct zero templates, host text on its way into owned
storage).

- ~~Object table rows are never reused~~ — **closed.**  A handle is
  `{index, generation}` and a freed row goes on a free list, so the
  table grows to a program's peak object count rather than to the
  number of objects it ever made, and S9 stays a clean
  `use_after_free` trap because a stale handle's generation is not the
  row's (docs/MEMORY.md).  Measured on a loop making and freeing one
  list per iteration: **281 MB → 21.2 MB at 1M iterations, 593 MB →
  21.3 MB at 4M**, flat where it was linear.
- ~~string bytes go to a run-lifetime arena and are never reclaimed~~
  — **closed.**  A string's bytes and a struct's field run have
  exactly one owner, and any store into something that outlives the
  current statement copies them, so no owner ever holds a view of
  bytes it did not allocate (`docs/STRINGS.md`).  The same churn loop
  — one string built and discarded per iteration, retaining nothing —
  read off the runtime's own arena: **15.5 / 29.4 / 59.9 / 121.0 MB →
  1.8 / 1.8 / 1.9 / 1.8 MB at 0.5M / 1M / 2M / 4M iterations**, and
  flat out to 16M; in the artifact, 20.4 MB of allocator working set
  and equally flat.  Reference counting, ARC, COW and tracing GC stay
  permanently refused (`docs/MEMORY.md`); what replaced them is the
  language's own claim made literal — *values copy*.

The flagship program was the worked example and is now the proof.
`Editing.splice` (`examples/editor/editor.luc:146`) is
`value[0:cursor] + extra + value[cursor:len(value)]`, and 20,000
keystrokes into a 40 KB file peaked at **1204 MB RSS**.  The same
simulation now peaks at **3.3 MB**, and costs 24 µs a keystroke
instead of 9 — three orders of magnitude inside a 16 ms frame either
way.

What it cost, measured by `bench/compare.sh` on one host: five of the
six benchmarks moved less than 1%, and `bench/strings` went **2.35× C
→ 3.40× C**.  That was allocation, not copying — 800,000 small
allocate-and-free pairs where there used to be unreclaimed bump
allocations and shared views — and **small-string optimisation took
most of it back**: a string of 22 bytes or fewer now lives inside the
`Value` holding it, `string(long)` and `chr` never allocate at all, and
`bench/strings` came back to **within 12% of where it stood before
copy-on-store** (step 5 of `docs/STRINGS.md`, which records the
phase-by-phase measurement).

Commits: `8bf0abc`, `89c7bcb` (generational handles), `806035d`,
`59953f7` (string bytes have an owner).  The remainder of that string
row — the part small-string optimisation did not take back — is
**still open** and is in MISSING.md's summary, not here.

---

## 2026-08-03 — Tier 0, item 2: the engine that reaches C parity cannot be run

**What was missing.** The LLVM backend existed and nothing could start
a program through it.

**How it closed.** It is the only engine now.  **A `.lc` *is* machine
code** — the tagged shared library `luce build` writes — and `loom run
FILE.lc` is one `dlopen`, one symbol lookup and one call.  `--emit=exe`
writes a standalone binary, `--emit=object` a relocatable object, and
there is nothing left to fall back to or select between
(docs/ENGINE.md).

What that delivered, measured through `loom run` against the engine it
replaced, **while there was still one to measure against**: **loops
6995 ms → 92 ms, matmul 5767 ms → 22 ms, strings 931 ms → 57 ms.**
Startup is 3–4 ms and compiles nothing; compiling is `luce build`'s job
and happens when it is asked for.

The three decisions, all in `docs/CODEGEN.md`: `cc` links, at build
time only, so the *run* path still invokes nothing; a standalone binary
gets **loom's own host**, terminal included, because a program's
behaviour must not depend on who started it; and every artifact carries
an `artifact.Artifact` tag — machine, ABI version, a content hash of the
program, and the identity of the code generator — so a stale or foreign
one is refused by name instead of crashing.  The key is content, never
mtime.

Commits: `4896cc5`, `3521233`, `8386db3`, `2e227c2`, `1537f19`.
Two consequences named in `docs/ENGINE.md` are **not** closed and stay
in MISSING.md: an artifact is mostly `libluce_rt` by size, and a `.lc`
runs only on the machine that built it.

---

## 2026-08-03 — Tier 1: the semantic hole, both halves

**Optionals.** `T?`, `none`, narrowing and `else` lower to `{T, i1}`
through LLVM, so a program that says `T?` is compiled like any other.
What the lowering cost that `docs/FAILURE.md` did not predict is one
refused shortcut, recorded in docs/CODEGEN.md: the null handle cannot
stand in for absence, because it already names a value that is *there*.

**Errors.** `T!`, `try`, `catch` and `error(...)` lower through LLVM as
the outcome word a Luce function already answered, so the success path
of a `try` reads nothing at all.  `T!` really did leave `types.Type`
untouched — fallibility is a bool on `mir.Function`, and not one `Type`
switch grew an arm — which is the one prediction docs/FAILURE.md made
about the cost that survived contact whole.  What it got wrong is
recorded there: ABI 6 rather than 5, `catch` needing a statement form as
well as an expression one, and `file_write` having to become fallible
too.

**The corpus that argued for it, item by item** — this is the evidence,
and it is written nowhere else:

- `dice.luc:41` — `if files.write_lines(...)` with **no else**, a
  silently swallowed write failure.  **Fixed, and unwritable**: the
  call answers nothing, so there is no bool to test and no branch to
  forget, and `main() -> !` reports what the disk said.
- `editor.luc`, `wordcount.luc` — an existence check then
  `file_read`.  **Both gone.**  One read each, and what it answers
  decides: `catch:` sets the editor's greeting, `try` ends wordcount
  with the path it could not open.  What that removes is a window
  between two calls that nothing could close, and a guard that could
  not tell "not there" from "would not open" anyway.
- `calc.luc` — four `trap(...)` calls about the *user's* typing.  Now
  four `error(...)` calls carried up through four frames of recursion
  by `try`, with no `if` written for any of them.  It is the worked
  example.
- `std/files.luc` — real signatures throughout.

Commits: `81774d0` (optionals lowered), `72fe8be`, `4ec770a`.
Detail: `docs/FAILURE.md`.

---

## 2026-08-04 — integer division spelling

Both workarounds the entry named by line are gone: `bf.luc:42` is
`(tape[pointer] - 1) % 256`, the spelling its author meant, and
`math.luc`'s sign-safe parity is `long(y) % 2 == 1`.  `/` became real
division in the same memo.  Detail: `docs/NUMERICS.md`.

## 2026-08-04 — no multiple returns (polished 2026-08-08)

`-> (A, B)`, `return a, b`, `let low, high = f()`, and the later polish
`low, high = f()` into existing mutable bare names, lowered as a
compiler-synthesized struct.  `calc.luc`'s `struct Step` is deleted, and
with it four more disguises of the same missing sentence: a heap object
as a mutable cell, a second value dropped and guessed, a second value
thrown away and fetched again, and two traversals for one pass.  Detail:
`docs/RETURNS.md`.

## 2026-08-05 — `catch` cannot see the reason

**What was missing.** A handler could tell that a call failed and not
why.

**How it closed.** `CALL catch NAME:` binds the error's message to an
immutable `string` scoped to the handler block, and both callers the
entry named took it: `calc.luc`'s REPL prints what the parser raised
instead of the line the user typed, and `editor.luc`'s save shows the
runtime's sentence instead of building its own copy of it.  The binding
is the message and not the code — a `catch` guards one call and one call
raises with one code — and not the raise position, which is what the
report for an error nobody caught is for.  The expression form still
takes no binding, with reasons.

Detail: `docs/FAILURE.md`, As-shipped note.  Commits: `28bc7fd`,
`8008b2b`, `ec28a02`.

---

## 2026-08-06 — no default or named arguments

`term_style(fg, bg, bold)` was called 15 times across `examples/` and 14
ended in the same noise word `false`.  Every parameter now has a name a
call site may write, defaults are trailing folded constants, struct
fields take the same clause, and the builtin table carries
`term_style(fg, bg = -1, bold = false)` — the fifteen sites write the
argument that varies and nothing else.  Detail: `docs/ARGS.md`.

## 2026-08-06 — no visibility

std leaked `is_space_byte` and `fold_case`.  Public by default;
`private` in full, per declaration and as struct regions;
`luce.sema.private` at every resolution site, both spellings of the
strings leak included; six markers and the `math.rng(seed)` factory are
the whole migration.  Detail: `docs/VISIBILITY.md`.

## 2026-08-06 — no bitwise operators, no hex literals, no digit separators

`& | ^ ~ << >>` on the integers at Go's precedence, shifts as bit
transport with the count checked (`shift_out_of_range`), `0xFF`,
`0b1010`, `_` separators; octal stays refused by name.  What it
unblocked is `std.zip` — CRC-32 and Huffman without division-and-modulo
soup.  Detail: `docs/BITWISE.md`.

## 2026-08-06 — path manipulation

Shipped as `std.paths`.  It was never a host gap — joining and splitting
a path is pure text, so it is a std module over `strings` — and it
waited to be designed against a program that needed it rather than
guessed at.  Commit `ebd191d`.

---

## 2026-08-06 — Tier 2, the enum half

**What was missing.** Every set of named constants was a `long` with a
comment, and every dispatch over one an `elif` chain with no compiler
behind it.

**How it closed.** `enum Method:` and `enum Method(byte):`, members
namespaced and folding as constants, `int(m)`/`string(m)` and
`Method(n) -> Method?`, equality only, methods and namespace functions,
containers at the backing width — and `match`, with an arm for every
member or an `else`.  `std.zip` converted the day it landed.  Detail:
`docs/ENUMS.md`.  Commits: `cfcf980`, `19afdb3`, `dd933ad`.

**The corpus debt it paid, and the two things the rewrite found** —
recorded nowhere else:

- key handling was one `elif` chain of **15 string comparisons** with
  no final `else`, so a misspelled `"page_dwon"` compiled and silently
  did nothing.  It is `enum Intent` — sixteen members, the host's key
  names translated to it once at the edge, the unbound case named
  `ignored` rather than fallen through, and a `match` with an arm for
  every member.  Past `Intent.of` the editor never compares a string
  to decide what to do.
- `# 1 keyword, 2 type name, 3 builtin, 0 plain.` — an enum written as
  a long with a comment — is `enum Word`, and the `elif` chain over
  those numbers is a four-arm `match` with no `else`.
- `is_keyword`/`is_builtin` as **46 `word == "…"` comparisons** — a
  hash set written as a truth table — first became two space-fenced
  strings, then immutable `map(string, bool)` constants once the
  language could state them.  Lookup is now O(1), the compiler rejects
  a duplicate key, and the boundary left is the hand-maintained copy of
  the compiler vocabulary rather than the data structure.

Two things the rewrite found that no feature would have: the word
lists had drifted eight language generations (ten keywords and
twenty-one builtins missing, two names present that are not free
builtins), and an enum member may not be named `insert`, because the
list-method table reserves it.

Commit `0719607`.  The hand-maintained vocabulary copy is **still
open** and stays in MISSING.md.

---

## 2026-08-07 — Tier 3b: the binary boundary

**What was missing**, and the `std.zip` run measured it rather than
guessing at it: **Luce could not read or write an arbitrary binary file
in either direction.**  `src/apps/host.zig` refused anything that was
not valid UTF-8 — deliberately, because a half-read JPEG handed over as
a `string` would make every string guarantee a lie — and the writing
direction was closed by construction, since a `string` *is* valid UTF-8
and nothing could build one that is not.  So `std.zip` shipped as a
complete byte-buffer library that no real archive could reach.

**Closed** (docs/BYTES.md, ratified R1–R5 and built).  Three things
that were one movement:

- **`list(T)` stores its elements at their real width.**  A
  `list(byte)` is one byte an element where it was twenty-four; the
  boxed slot survives for the kinds that need it (strings, structs,
  objects), and `map` is untouched.  No surface changed, and the
  interleaved A/B on every benchmark row moved nothing outside noise.
- **A file is bytes reached through an open handle.**  `file` is a
  heap type and a **scope-owned resource**: `files.open(path)` answers
  one, the owning scope's end closes it, `free(f)` closes it early,
  and a use after close traps `use_after_free` because it is the same
  mistake.  The primitive is C-shaped — a read fills the caller's
  buffer and answers the count, a write takes a buffer and a length —
  which is the shape `std.network`'s sockets are meant to reuse.
- **Text is a validation the language performs on the bytes.**  The
  UTF-8 check moved out of the hosts and into `libluce_rt`, so the
  interpreter, a compiled artifact and every future host agree
  byte-for-byte on what "not text" means.  `strings.to_bytes` is
  total and `strings.from_bytes` answers `string?`.

Commits: `7318fd3`, `93171dd`, `e43f15d`, `0c51a03`, `f8997cb`.
What is left of the item is smaller, named in `docs/BYTES.md`, and
stays in MISSING.md: no seek on a handle, and no file metadata.

---

## 2026-08-07 — function values and lambdas; sort with a comparator

`func(T, ...) -> R` is a value type, a named function becomes a value
where one is expected, and `(a, b) -> expression` is a capture-free
lambda whose parameter types come from its landing place.  `std.lists`
supplies stable O(n log n) `xs.sort_by(before)` for every list element
type — ordinary Luce behind an import-routed method, not a builtin.
Detail: `docs/FUNCTIONS.md`, D6 as the proving customer.  Commits:
`9c728a7`, `bda1c02`, `589efe1`.

## 2026-08-07 — workers, and the `task` resource

`spawn f(args)` onto a runtime of its own, `task(T)` as a scope-owned
resource whose scope end is a join.  Detail: `docs/THREADS.md`.
Commits: `863c556`, `3f4b8d1`, `174b043`.

---

## 2026-08-08 — no receivers on user structs

Every plain member has implied `self`; a namespace member says
`static func`.  Whether a method writes the receiver is inferred
transitively, and a writer aliases one bare owning `var` binding in
place.  Detail: `docs/SELF.md`, superseding the receiver design in
`docs/METHODS.md`.  Commit `ae0f39f`.

**The measurement that argued it, and the refutation it produced** —
recorded nowhere else.  The 88 namespaced calls were **not** 88 waiting
method calls: they are calls on *folders*, and a folder has no
receiver; not one function in the corpus had the enclosing struct as its
first parameter.  The harvest was the restructuring the feature permits:
`Handle`'s four functions and two of `Draw`'s merged into `struct
State`, and `std/math.luc`'s `list(long)`-as-a-cell workaround became
`struct Rng`.

## 2026-08-08 — no constant containers

File scope uses `const` for folded values and flat program-root lists,
maps and rank-1 arrays.  The editor's two truth tables are immutable
`map(string, bool)` literals with O(1) `has`, and `std.zip`'s six
printed tables are built once per runtime rather than once per call.
Duplicate constant-map keys are refused.  Detail: `docs/CONSTANTS.md`.
Commit `25738aa`.  **There is still no `set(T)`** and that remains in
MISSING.md, deliberately: a constant `map(T, bool)` covers every caller
the corpus has.

## 2026-08-08 — the six channel prerequisites, and the seams closed with them

The language-lock audit found six channel-prerequisite checks; all six
closed before channel syntax could be frozen, and subsequent closeout
reviews closed three more design-independent seams.  A failure-path
audit made the existing cross-runtime copy primitive transactional
before a queue can depend on it.  This is the ledger, and it is written
nowhere else:

- **Closed here:** LLVM's runtime table now withholds `willreturn` from
  exactly the calls that cannot promise termination.  The direct
  host/blocking set is `report`, `report_error`, `args_list`,
  `file_open`, `file_read`, `file_write`, `file_flush`,
  `file_read_text`, `file_write_text`, `spawn`, `task_wait`, and
  `effects_enter`.  Resource release can transitively call the host's
  close callback, so `close`, `constants_abort`, `discard_loose`,
  `unbind`, `free`, `index_set`, `remove`, and `clear` withhold it too.
  `copy`, `list_slice`, and `map_values` also withhold it: ownership
  cycles are now refused, but an acyclic graph's native recursive depth
  remains data-dependent and can exhaust the stack.  `map_keys` stays
  true because map keys are non-owning `long` or `string` values — an
  enum key is one of them, since it is stored as the integer a `long`
  key would be (docs/ENUMS.md).  All other services are pinned
  `willreturn = true`; `nounwind` remains unchanged.
  Colocated Debug and ReleaseSafe tests pin the exact twenty-three-service
  false set and every remaining true entry.
- **Closed before channels:** the real host's growable worker table and
  both spec hosts' fixed worker tables now own a registry mutex rather
  than borrowing D9's Effects lock.  A spawn starts outside the lock and
  publishes under it; join and teardown detach a row under the lock and
  wait only after releasing it.  Closing refuses later publication and
  drains one detached thread at a time, so a worker waiting for or
  spawning a nested worker cannot deadlock the registry.  Production
  handles remain append-only; the fixed spec tables reuse storage but
  assign a new monotonic identity before reuse, so a stale task cannot
  join the row's next worker.  Contention, closing and stable-handle tests
  run in Debug and ReleaseSafe, and a two-engine program has eight
  siblings each spawn and join a child.
- **Closed before channels:** every host open, read, write and flush
  callback now takes the shared Effects guard, including each callback
  inside the whole-file text loops.  Allocation, validation and loop
  bookkeeping remain outside the guard, so workers can progress between
  callbacks.  The MIR classifies whole-file operations as runtime-mediated,
  so the oracle does not add a second operation-wide guard which the
  compiled path lacks.  A concurrent runtime test detects both overlap and
  a guard held beyond the one callback; a MIR test pins that engine seam.
- **Closed before channels:** the public oracle now states the allocator
  contract its real worker threads already require.  A worker-enabled
  `interpreter.run` shares `Memory.objects` across the root and worker
  runtimes, so that allocator and any backing allocator shared with
  `Memory.arena` must support concurrent calls through the structured
  joins.  The compiled runtime and the executable-spec host already use
  thread-safe allocators; the contract keeps a caller-supplied allocator
  from being mistaken for an unchecked private one.
- **Closed before channels:** a failed cross-runtime re-own now reports a
  stale handle or forbidden resource on the source runtime that initiated
  the handoff, clears the target's private pending trap, and leaves every
  partially copied row rolled back.  Allocation failure remains allocation
  failure rather than being translated into a language trap.
- **Closed before channels:** verified MIR no longer admits `heap_new` for
  `file` or `task`.  Resources enter only through file-open and worker-spawn,
  so malformed decoded modules are refused before either engine reaches an
  impossible constructor.
- **Closed here:** a container or struct that transitively carries
  `file` or `task` is now refused statically by `copy` and at every
  worker-runtime boundary.  The runtime's `not_owned` trap remains a
  defense, not the source-language rule.  Ownership diagnostics are
  type- and ownership-aware at the same boundary.  They offer `give`
  only for a live owning name; a borrowed resource parameter names the
  signature, every caller and the retaining handoff; a known alias names
  its owner; an ownerless view names an ownership-returning operation or
  restructuring; and an invalid `copy`/`give` in a borrowing context
  says to remove the verb.  Active-loop and direct-`free` contexts have
  their own valid repairs rather than an impossible `copy` or `give`.
- **Closed here:** the other two deep-copying surfaces share that
  resource-graph gate.  A list slice whose element type carries `file`
  or `task` is refused unless both effective bounds are equal
  compile-time `long` constants, which proves that the runtime copies
  zero elements; the direct `[0:0]` case and the bound-type diagnostic
  precedence are pinned.  `map.values()` remains type-driven and is
  refused whenever its value type carries a resource, even for an empty
  map.
- **Closed here:** current reference/highlighter coverage now keeps
  `task.wait()` in the method roster, so the next receiver surface
  cannot drift silently.
- **Closed before channels:** an owner cannot be stored into itself or
  one of its descendants.  Stage 4 rejects the relationship when a
  visible place chain exposes it.  A store into an existing container
  walks its exact parent chain before mutation; a fresh deep-copy or
  derived container or object cannot already be an ancestor, so
  attachment records its children's exact parent at commit.  Parameters
  and aliases cannot therefore hide a cycle: those hidden cases trap
  `ownership_cycle` (“attempted store would create an ownership cycle”).
  The appended stable trap moves `module.format_version` 33 → 34;
  `abi.version` stays 13.
- **Closed before channels:** a successful host open remains locally
  owned until `Runtime.newFile` attaches its resource row.  Either
  allocation failure closes that raw handle exactly once under Effects
  and preserves the original `OutOfMemory`; an open slot without a close
  slot fails `host_unavailable` before acquiring anything.  Failing-
  allocator tests cover both allocation points, the handle census, the
  guard depth and every returned byte.
- **Closed before channels:** `Runtime.copyFrom` now rolls back every
  copied child row and owned value run when a later list, map, array or
  struct allocation fails.  The same rule covers list slices, map
  `values()`, the other list-building helpers, partially moved worker
  arguments, and a worker result stranded when its task row cannot be
  allocated.  Fail-index tests require the target live count and byte
  census to return to their baseline at every refusal.  Packed-list copy
  also copies live cells rather than retained spare capacity.

Two later language-lock repairs closed too.  Empty constant `[]` now
checks flatness from its annotated element type before there are
elements to walk, so `list(task(long))`, nested-container and optional
empty constants cannot bypass the ordinary boundary.  Shaped returns
preflight visible ownership roots and explicit `give`, then record each
owning bare name's replacement revision when that operand is staged.  A
writer to the left is accepted because a later bare name stages the new
value; a handoff or writer to the right cannot invalidate an old value
already staged, and one graph cannot escape through two results.
Ordinary resource `x = x` or `x = alias_of_x` reassignment is likewise
refused directly instead of being told to give a name to itself.

Commits: `f775d8c`, `57b9656`, `bc07836`, `545b028`.

---

## 2026-08-10 — Tier 2, the union half

Members carrying named payload fields, constructed as namespaced calls
with named arguments; `match` extended with payload arms that bind each
field by its own name as an alias — the only door to a payload, so
wrong-arm access is unrepresentable; ownership with no new rule; the
zero as the first declared member; recursion through owning containers
with `Shape?` as the terminator that is not one; and a value that is a
struct-shaped run `libluce_rt` walks without ever learning unions
exist.  Eighteen decisions shipped as written on the day they were
scheduled, three held questions taken as their written recommendations,
two recorded departures (the padded run and the refused `free(u)`),
`format_version` 37 → 38, and `libluce_rt` untouched.  Detail:
`docs/UNION.md`, *As built*.  Commits: `0442cf3`, `6b61cf8`.

**What that closed that was not the feature.** Tagged unions were,
until that run, the second-order blocker `docs/FAILURE.md` refused
`Result<T, E>` for, which is what forced `T!` to be a function
attribute.  That refusal **stands** even with the blocker gone: R3
promised this run nothing about error shapes, the attribute is what gave
Luce Ok-wrapping for free and kept `types.Type` out of the feature
entirely, and whether an error reason may one day be a value-only union
is a question `std.json`'s callers get to ask.  `T?` was *not* subsumed
— D14 kept it its own mechanism, for the five reasons the research
priced — and `Shape?` became writable instead, which is what gives a
recursive union a terminator that is not a container.

## 2026-08-10 — the cheap library slice, and the sentinels

Three things, landed before the first packages could bake the warts in.

- **The six ASCII character classes** — `is_digit`, `is_upper`,
  `is_lower`, `is_alpha`, `is_alnum`, `is_space` — in `std.strings`, on
  the byte the primitives answer, with bytes above 127 in none of them.
  The three hand-rolled copies in the corpus went with them.
- **`m.get(k)` answers `V?`**, so a hit costs one hash lookup and the
  `has`-then-index pattern has nothing left to recommend it.
- **`strings.find` and `xs.find` answer `long?`.**  `find` returned
  `-1` because `long?` did not exist; the two-declaration half had
  already settled, with `find_from` merged into
  `find(s, needle, start = 0)` (docs/ARGS.md §9).  A caller who wants
  the sentinel writes `... else -1` once, spelled out.

Detail: `docs/STD.md`.  Commits: `a7b69ff`, `157b128`.  Two remainders
stay in MISSING.md: the `set` question, and `find`'s empty-needle
disagreement with `count`.

## 2026-08-11 — Tier 5: stage 5 (HIR) is unwritten

Stage 4's walk checks and records a typed tree and emits nothing, and
`05_hir/lower.zig` is the one emission — a mechanical, diagnostic-free
lowering whose error set is `OutOfMemory` alone.  Compound assignment,
`for x in xs`, `match`, the short-circuits and the fallible forms all
reach it as structured nodes and are desugared there.  `builder.zig`
went 12,532 → 2,154 lines and `declarations.zig` 3,579 → 537 as both
passes became families of files over one type.  Detail:
`docs/PIPELINE.md` row 7 and the `05_hir.zig` barrel header.  Commits:
`ca1355c` through `27b8626`.

**One desugaring is still upstream of the tree** and stays in
MISSING.md: `03_parse` expands f-strings and `elif` chains while it has
nothing but syntax.  So does the warning the stage carries, which
outranks all of it: **whole-array operations must survive as single
nodes**.

## 2026-08-11 — Tier 5: no `luce test`

A test is a top-level public zero-parameter `func test_*()` in an
ordinary `.luc` file, asserting with the `assert` the language already
had; `luce test` sweeps `./tests` or the paths it is given, refuses by
name every `test_*` that could never run, compiles each file once with a
**compiler-synthesized** `func main(args: list(string)) -> !`, and calls
the artifact **once per test** — so per-test isolation is the `Runtime`
that already existed and a trap fails one test rather than the run.  A
first draft put each test in a worker runtime and was found structurally
unable to keep that promise, because a worker's trap is final at the
join; the memo records both.  Detail: `docs/TESTING.md`, including its
"Deliberately absent" — no assertion library, no fixtures, no filtering,
no mocking, no parallelism.  Commit `de5dacb`.

## 2026-08-11 — bound methods, and a storable function value

`receiver.method` written where a `func(T, ...) -> R` lands is a
function value whose environment is the receiver, with the receiver's
parameter dropped from the written type and no marker.  A value-only
receiver is copied in; a carrying receiver is **borrowed**, so the
owning bind (`give counter.bump`) is refused and `carriesObjects` of a
function value is exactly false rather than conservatively so.  `==` on
a function value is refused with it (D6, retiring FUNCTIONS D3), and no
function value crosses a worker boundary for the same reason.  Union
member constructors are function values (D11).  A function value is
storable (D7): `(func(...) -> R)?` is the form a struct field, a list
element, an array cell and a union payload field hold one in, absence is
the zero, and a map value is written bare because `get` already answers
`V?`.  Detail: `docs/BINDING.md`, all three *As built* sections.
Commits: `39c0525`, `e6b7b10`, `844b131`.  **D8 is outstanding** —
`func(T) -> R!` does not exist — and stays in MISSING.md.

## 2026-08-11 — packages, the consuming half

A program under a `luce.yaml` resolves dotted imports, hand-vendored
packages in `.luce/packages/`, `LUCE_LIB` shelves and `path:` overrides
at exact versions with content hashes, diamonds refused with `override:`
as the remedy, and compiles into `.luce/cache/`.  Detail:
`docs/PACKAGES.md`, five steps with as-built notes.  Commits: `70b31b2`,
`b8bc2a2`, `ee2bfd7`, `5428306`.  **Producing and fetching are not
built** and stay in MISSING.md.

---

## 2026-08-11 — the directory is the one that bites

**Closed** (ABI 16).  `dir_create(path)` is the slot the entry asked
for, beside `dir_list` and with `files.make_directory` over it: one
optional service, fail-closed, answering `yes`/`no`.  Two decisions came
with it, and they are one decision said twice — the call means *there is
a directory at this path when I return*.  It makes **every directory
leading to the one asked for**, because both of its callers want a
nested layout (a package store writing `.luce/packages/NAME-VERSION/`,
an extractor writing under a directory the archive named) and the
alternative puts the same splitting loop in every program; and a
directory that was **already there is success**, because the alternative
makes every install path write `if not files.is_dir(p)` in front of the
call, which is exactly the check-then-act race such a question is
documented never to be a guard against.  A *file* holding the name is
still `io_failed`.  `examples/zipper/zipper.luc` was the program that
proved the ceiling and is the program that shows it gone: the pre-pass
that named a missing directory and refused the archive is now a
`make_directory` call, so an archive with `papers/note.txt` in it
extracts into an empty directory the way `unzip` does.

## 2026-08-11 — a wall clock

**Shipped as `epoch_ms`** (ABI 16), milliseconds since the Unix epoch.
It is a second builtin rather than a mode of `clock_ms` because the two
answer different questions and confusing them is the classic bug in both
directions: a span measured with a clock an operator can set back comes
out negative, and a record stamped with a monotonic reading means
nothing off the machine that made it.  The name says what it counts
from, so neither can be read as the other.  It takes the machine facts'
fallible slot shape — a host with no calendar answers "cannot tell" and
the program traps `host_unavailable` — rather than inventing a date.
**The calendar is still not here**: turning milliseconds into a date is
a library, not a builtin, and the library does not exist.  This is the
number it will be built on.

---

## 2026-08-12 — a program can ask what is at a path

~~**And no way to ask what is at a path**~~ — **closed** (ABI 17,
docs/FILESYSTEM.md).  The entry's own sentence — "no way to tell a
directory from a file except by trying to read it" — was the last thing
in it that a program actually hit, and two programs in this tree were
paying for it.  `path_kind` is the appended slot: `yes` with 0 nothing /
1 file / 2 directory / 3 other, links followed, and `no` for a world
that would not say.  `files.kind(path) -> Kind?!` is over it, and
`files.exists`, `files.is_file`, `files.is_dir` and `files.entries` are
over that.  `file_exists` retired in the same bump and its bool went
with it: it answered `false` both for a name nothing holds and for a
file under a `chmod 000` parent, which are two facts, and a program
could not tell them apart.

The two programs are the proof, and neither is hypothetical.
`examples/editor/editor.luc`'s file pane listed `.` and read whatever
was selected, so choosing a subdirectory produced *"cannot read src"*
and nothing to do about it — it now lists `files.entries`, marks
directories with a trailing `/` and **walks into one**, with a `../`
row to walk back.  `examples/zipper/zipper.luc:116` wrote `if not
files.exists(into)` where `into` must be a *directory*, so a file in
the way sailed through the gate and failed later inside the extraction
loop; it asks `files.is_dir` now and refuses up front, leaving the
file untouched.

What remains unasked, deliberately: **`stat`** — size, times, mode,
owner, inode.  Every field is a promise the ABI must keep on every
platform and no current customer wants one; the two usual reasons are
answered elsewhere (the compile cache keys on the program's content
hash, and "how big is it" is answered by reading it, since a size read
before a read is the same race an existence check was).  If a customer
names a field, that field and only it gets designed.

Commit `cdf3502`.  `open()`, `FileMode` and the file-surface methods are
the named remainder in `docs/FILESYSTEM.md` and stay in MISSING.md.

## 2026-08-12 — `std.json` rewritten onto unions

`std.json` was the customer unions were argued from, and it had been
written without them as an `enum Kind` + `struct Node` + flat
document-of-indices design.  It is now a `union Json`: `match` is the
whole navigation API, the navigation type disappeared, and the module's
only new cost is a call frame per level of nesting, which moved its
bound from 128 to 64.  Nothing in the compiler or the runtime moved to
allow it.  Detail: `docs/UNION.md`, "The customer, two days later".
Commit `d3fdc40`.

## 2026-08-12 — a field of an element needs a `var` root binding

**What was missing.** `xs[i] = v` through a `let`-bound list was
ordinary content mutation (S38) and `xs[i].field = v` through the same
binding was refused — "`xs` is let-bound; use var for reassignment" —
because the place rule walked to the root binding and a nested place
rebuilt value structs up to it.  Nothing was being reassigned: the write
lands in the container either way.  `self.things[i].at = …` was refused
for the same reason, which is why `examples/adventure/world.luc` opened
seven of its methods with `var slots = self.<table>`.

**How it closed.** A nested place now says what lands on it, and stops
at the innermost container when the path crosses one — which is what
the assignment rule already described.  Both shapes compile: `xs[0].n =
2` through a `let`-bound list, and `self.rooms[at].seen = true` inside a
method.  Commit `f12c601`.  The corpus has **not** been swept of the
workaround the restriction forced, and that sweep is in MISSING.md.

## 2026-08-12 — `termui` 0.1.0, and `loom edit`

The first package: five modules, twenty-nine tests, a diffed cell grid,
four total splits, one `Event` union with a `Key` enum, and no widget
tree.  The editor migrated onto it in step 5.  Detail: `docs/TERMUI.md`,
its two *As built* sections.  Commits: `5dd11ba`, `fe48239`.

**`loom edit` is retired, by the owner's call** (2026-08-12): *"packages
should be linked statically.  We'll deal with dynamic linking later.  We
don't actually need loom edit, because we have an editor that we can
install."*  The embedded editor, `LOOM_EDITOR`, the `edit` shell command
and the direct CLI form all went, and `files.MemoryLoader` — whose only
customer they were — went with them.  PACKAGES.md's "the embedded editor
must keep working pathlessly" was a *named requirement* on step 3, so it
is recorded as retired rather than quietly deleted.

What the migration bought, stated honestly: `editor.luc` is 1,262 →
1,141 lines but `editor_model.luc` is 14 → 189, so the editor is **54
lines longer** than it was, plus 149 lines of tests it never had.  The
memo's evidence table counted 373 lines of plumbing and nothing like
that went away.

## 2026-08-12 — the license contradiction

`CONTRIBUTING.md` carried two incompatible license statements — one
saying there is no license and the tree is exclusively copyrighted, the
next saying submitted contributions are dual MIT/Apache.  One policy
survives: the dual-license section under `## License`.

---

## Diagnostics: the three rounds, 2026-08-04 through 2026-08-08

A hostile-user sweep of ~110 wrong programs across the lexer, parser and
analyzer produced a ranked list of diagnostics below the standard the
ownership, optional and failure families set.  Twenty-five of them
closed over three rounds; what is left is in MISSING.md's Tier 5b.

**Two rules came out of the work and are worth carrying forward:**
**one mistake, one report** — which is now a mechanism (`Lexed.truncated`
per file, statement-scoped suppression per construct) and not a habit —
and **check in the order the reader needs**, after a `try` diagnostic
was found giving advice that cost a signature edit and a recompile to
disprove.

**Round one.** The method and built-in **argument** diagnostics went
first — one sentence used to cover both a wrong count and a wrong type,
phrased as a count, with the caret on the whole call.  Then eleven more,
each pinned by a spec asserting code, wording and column:

- ~~A namespace used without a call denies its own import~~ — and it
  was wider than reported.  `math.seed`, `P.make` and a bare `helper`
  all answered "unknown name" about a declaration the compiler had
  just checked.  Field access on a bare declaration name now resolves
  as a namespace, exactly as it already did in front of a call, and a
  name in value position that names a declaration says what it is.
  Today the diagnostic offers both valid uses: write `helper(...)` to
  call it, or annotate the place it goes with the function type it
  should wear.  Suggestions come from that namespace's own members.
- ~~A mutual struct cycle reports twice, and both messages are
  false~~ — one message per cycle now, walking the loop that closes
  it (*struct A contains itself: A.b is B, and B.a is A*), caret on
  the field rather than the `struct` keyword, and carrying the fix
  `LANGUAGE.md` only ever spelled in prose: `b: B?`.  A spec compiles
  that suggestion, because a message whose fix does not work is worse
  than one that does not help.
- ~~Only the first missing struct field is reported~~ — all of them,
  in declaration order, with the conjunction English wants.
- ~~`script entry must be exactly func main():` is not true~~ — the
  return-type diagnostic now enumerates all four legal entries: no
  parameter or one `list(string)` command-line parameter, each with or
  without `-> !`.  Parameter and return mistakes have separate sentences,
  with the caret on the return type or parameter rather than `func main`.
- ~~Over-nested blocks produce 152 diagnostics and 215 KB~~ — one
  message and 305 bytes.  The bound reports once and stops; `lex()`
  answers `Lexed{tokens, truncated}` and the parser falls silent on a
  cut stream, which is what `03_parse.zig`'s stated invariant always
  claimed.
- ~~`1.2.3` names the wrong thing and prints harmful advice~~ — it
  names the second decimal point and says what was read instead, and
  the extra run is swallowed so the parser adds nothing.  Its mirror
  `1.` gets `.5`'s model message; `5.foo` is still member access.
- ~~`and`/`or` will not say which side or what it is~~ — *the left
  operand of and must be bool, not long*, underlining that operand
  alone, with the absence advice the right side never had.
- ~~Duplicate-name diagnostics never point at the first
  declaration~~ — all four spellings do, naming the file too when the
  first is in another one.
- ~~`operands are string and long (conversions are explicit)`~~ — names
  the operator, and offers a conversion only where one exists
  (`long()` takes a double and `double()` takes a long, and that is the
  whole set).  `let` no longer offers a `string(...)` by name.
- ~~Grammar: "a long", "a long?"~~ — standardised on the variants that
  sidestep the article.
- ~~long source lines are never windowed~~ — past 100 characters a
  line is windowed around the caret with 30 characters of context and
  `...` for what is cut, measured in characters because the caret pads
  per character.

**Round two**, the six that were ranked plus four found while sweeping:

- ~~Foreign operators get "expected an expression, found '+'"~~ —
  `++` `--` `**` `===` `!==` `<>` `<<` `>>` report once, with the
  caret across the operator as written and the Luce spelling in the
  sentence.  The bar for claiming a pair is that it can never be
  anything else: `a--b` *is* `a - (-b)` and still compiles, so `--`
  is claimed only where no operand follows, and the halves must
  touch or nothing is claimed.  `&&` and `||` never become tokens at
  all and are answered in the lexer, in the same words.
- ~~Stray-character diagnostics cascade~~ — the `Lexed.truncated`
  rule, narrowed to one construct: a parse report is suppressed when
  stage 2 spoke inside the source the current statement consumed.
  Scoped to the statement, so one bad line does not silence the next.
  `&&` 2→1, stray `$` 2→1, C braces 3→2.  A matched pair of
  typographic quotes is now one report across the whole literal,
  carrying both codepoints, and confined to one line so an unmatched
  quote cannot swallow a file.
- ~~No unreachable-code diagnostic~~ — **decided: refuse.**  The
  compiler has one severity, so warning was never available; the line
  the language already draws is between *misleading* and *redundant*,
  and a statement after `return` is the first kind.  It names the
  terminator and its line, an `if` counts only when every arm leaves,
  and one terminator is one report.  It found real dead code in two
  of the tree's own fixtures on its first run.  LANGUAGE.md and
  /ref/statements carry the reasoning.
- ~~A diagnostic at end of file prints no snippet~~ — the position
  was never wrong, so it does not move; the snippet borrows the last
  line with content and the caret sits one past its end, which is the
  same byte.  `Rendered.source_line_number` says which line it handed
  back.  Only at end of file: a blank line in the middle keeps its
  own emptiness.
- ~~An optional struct field is counted as one value~~ — **the
  recorded reasoning was wrong, and so was the guess it rested on.**
  Both counts are honest.  `valueCount` counts what a value of a type
  *unconditionally* costs, and `zeroOf` is what it predicts: it
  recurses through a struct field emitting an instruction per leaf and
  stops dead at an optional one.  Measured: twelve levels of two
  struct fields is 12,341 MIR instructions, sixty levels of the
  optional spelling is 201.  Flattening optionals as well cannot
  terminate (`next: Node?` has no closing order and would have to be
  called a cycle, destroying the fix the cycle diagnostic prescribes);
  flattening *neither* — the alternative the list proposed — disarms
  the bound, and ninety lines of source then took 2.76 GB to check.
  What was dishonest was the sentence, which described the data.  It
  now says the struct *always holds* the values, names the widest
  field with the caret on it, and offers `?` as well as a container.
- ~~`expectSayingAt` cannot see a left-operand span widening back~~ —
  `expectOnlySayingAcross` asserts the column an underline stops at,
  and both `and`/`or` left-operand cases are pinned by width.
- ~~A `try` with nothing to try gives wrong advice~~ — the order of
  two checks was the diagnostic.  Inside a plain `main`, `try
  plain()` answered "main does not say it can fail; write '-> !'",
  advice that costs a signature edit and a recompile to reach the
  truth; the same mistake in a `main() -> !` already got the right
  sentence.  The operand is asked first now.
- ~~`let a = risky() catch:`~~ — was "expected end of line after the
  binding, found the keyword 'catch'".  Now names the binding and
  both shapes that work.
- ~~An f-string hole is underlined by underlining the whole
  literal~~ — the synthesized `string(...)` carried the f-string's span,
  so four holes on one line were all underlined and one of them was
  wrong.  It takes the hole's span now.
- ~~`s[0:4:2]` blames the bracket~~ — says the language has two slice
  fields, where the third colon is written.

**Round three** closed `str takes long, double, bool, string, or
builder` by retiring `str` for `string(x)` (docs/NUMERICS.md): the
constructor's message names the type in hand, and an f-string hole
reports it at the hole.  `string(x)` has since grown two named-value
cases — enums and function values — without changing where the refusal
lands.  And `give b.items` — which said *"give moves a named object; use
copy for other expressions"* when a field **is** named and the real
reason is that a nested place cannot be moved out of — now says *"give
moves a bare owning name; pass a fresh expression without give, or copy
a resource-free borrowed expression"* and cites S10, S21 and S31.

**Swept with nothing to fix**, so the next sweep can start elsewhere:
the `give`/`copy` family (names the situation, its S-numbers and the
fix at every site tried), method and builtin arity and argument types,
index and slice type mistakes, the rest of the `T!`/`try`/`catch`
family, and `!x`, `//`, `else if`, `def`/`class`/`const`.

---

## Smaller closures, undated

Each of these was one entry in MISSING.md's "Resolved since the last
edition" list and needs no more than the sentence it had.

- **`key_read` can say the keyboard has run dry, and no longer wakes
  ten times a second doing nothing.**  It answers `string?`: `none` is
  end of input, the same fact `read_line` answers `none` for off the
  same descriptor (docs/FAILURE.md).  The two halves were one bug.
  Raw mode was `VMIN = 0, VTIME = 1`, so a read of zero bytes meant
  either "the timer expired" or "there will never be another key" and
  `nextKey` could not tell — it looped.  With `VMIN = 1, VTIME = 0`
  the read blocks, zero bytes means end of input and nothing else, and
  the idle wakeups go with it: measured 52 wakeups in five seconds
  before, 1 after.  On the compiled path the host's `no` was defined
  and read by nobody, which is where the loop actually lived.
- **Character literals — decided against; `ord("(")` folding verified
  working** in expressions and constants.  Adoption was zero when this
  was written and the corpus sweep it asks for is in MISSING.md.
- **`long.min` writable** — the sign folds before the range check.
- **`1e400` refused** — non-finite float literals are rejected.
- **`not a == b` and `a < b < c` are compile errors**, with messages
  naming both readings.
- **Four-space indentation enforced**; **CRLF sources compile**;
  **bidi controls refused everywhere**.
- **The `std.` namespace** — `import math` binds a sibling, `import
  std.math` binds the library, both together is a collision.
- **Trap locations and call traces**; **runaway recursion traps**
  rather than overflowing the machine's stack.  (That promise is
  `luce.sema`-level and about *Luce* frames; a native recursion in the
  runtime's own release walk is a separate, open item in MISSING.md.)
- **map is O(1)**, open-addressed over insertion-ordered entries.
  **Sort is O(n log n) and stable by guarantee.**
- **Build modes are settled, not pending.**  Luce is always
  `ReleaseSafe`; `--release` is closer to `-fstrip`.
- **`Bytes` is unconstructible** — cut (docs/ENGINE.md step 1): `var b:
  Bytes` compiled, nothing produced one and nothing consumed one, and it
  was one of the two things keeping stage 10 from being total.  A real
  `Bytes` would be designed fresh.
- **Host surface gaps** — nine services shipped at ABI 8: `read_line`
  (with its prompt), `print_error`, `clock_ms`, `sleep_ms`, `env`,
  `file_append`, `file_delete`, `file_rename`, `dir_list`, wrapped in
  `std.files`.  The two defects the item named are gone: **`calc.luc` is
  a REPL** (a line at a time, a bad expression reported and the loop
  continuing, a blank line or end of input to quit) and **`life.luc`
  animates** (each frame measured with `clock_ms` and the remainder of
  its 80 ms waited out, so `sleep_ms` is called with a negative number
  whenever a frame overruns — which is why it is not a trap).
- **`exit`** — shipped, and it is a host builtin like any other.  It
  waited because it is a fourth way for a run to end and every party
  needed an answer for it: `luce_main`'s `Status`, the leak census, what
  the oracle's frame stack does on the way out, and what "scope
  ownership" means when a scope never closes.  Those answers were
  written rather than guessed.
- **The VS Code grammar stops being hand-written.**
  `tools/vscode-luce/syntaxes/luce.tmLanguage.json` used to highlight
  removed v1 Fabric builtins and knew none of `give`, `copy`, `new`,
  `try`, `catch`, `none` or `import`.  It is now generated by
  `tools/grammar.zig` from the compiler's own keyword, symbol, builtin
  and method tables, and pinned byte-for-byte by a test in `zig build
  test`, so that drift cannot happen again in silence.
- **Also shipped:** f-strings, compound assignment, nested place
  assignment, the nine std modules, per-stage fuzzing.

---

## 2026-08-12 — five crashes behind one mistake: a refusal that asked a tag

These were never entries in MISSING.md.  They were found by a sweep on
2026-08-12, reproduced the same hour, and fixed the same day — and they
are recorded here rather than nowhere because the *shape* of the
mistake is the useful part, and it is a shape this codebase is
structurally prone to repeating.

**What they were.**  Five programs that `luce check` accepted and that
then panicked — four in the runtime, one in the compiler itself:

| the program | what happened |
|---|---|
| `a == b`, a struct holding a union whose arms carry differently-shaped payloads | `panic: for loop over objects with non-equal lengths` — and in ReleaseFast, with the bounds check gone, `Value`s read off an undefined slice pointer |
| `a == b`, a struct holding a `(func(…) -> R)?` field | `panic: reached unreachable code` |
| `xs.find(v)` / `xs.contains(v)` over a list of either | the same two panics, through a second door |
| `len(spawn work())`, `len(try file_open(…))` | `panic: reached unreachable code` |
| `m.values()` on a `map(K, func(…) -> R)` | **the compiler ICEd**, with no diagnostic, on a type no program can write |

**The one mistake.**  Three of them asked *a type's own tag* where the
honest question is what comparing the value **reaches**.  A struct's
`==` is defined as field-by-field `==`, so a single wrapper walked past
`operand_type == .function` and `== .variant` alike; `find`'s guard
looked one optional deep; `len`'s gate said `.heap` while its own
sentence listed five of the seven heap kinds, and `file` and `task` are
`.heap`.  The refusals were written about the spelling in front of them
rather than about the graph behind it.

**Why the existing walk was not reused, which is the part worth
keeping.**  `shapes.carries` already answers a transitive question and
is why the *worker boundary* refusal is correctly transitive.  It was
the obvious fix and it is the wrong one: `carries` walks **through**
containers, because `spawn` moves the whole graph, while equality stops
at an object handle — a handle compares by identity and its contents
are never read.  Reusing it would have refused
`struct Panel: buttons: list(Button)`, whose `==` is an honest handle
comparison.  So `incomparablePart` shares `carries`'s shape (iterative,
visited-checked, cycle-safe) and takes a different frontier, both walks
now say which frontier they take and why, and a spec pins the
`list(Button)` case precisely so that a future simplification into one
walk fails loudly.

**What UNION D16 had to concede.**  A struct carrying a union is not
comparable either.  Refusing `Shape == Shape` while permitting
`Box(Shape) == Box(Shape)` is the one position no reader can hold, and
"compare the tag, then only the live fields" is a decision D16
deliberately did not make and would have to be argued for the direct
spelling first.

**What CLAUDE.md and `08_llvm.zig` had said, and now say.**  Both
claimed there were no gaps — *"the lowering is total"*, *"nothing is
`unreachable` for 'not yet'"*, *"There is no list of gaps here because
there are none."*  The `m.values()` ICE falsified all three.  The
correction was not to write "there are gaps", because after the fix
there are none; it was to record the thing that was actually false:
these `unreachable`s are **nevers**, and a never is honest only while
something upstream refuses the shape it names.  Each now owes a stage-4
refusal *and* a verifier arm, and both files say so.

**The standard the fix had to meet**, and this is why it took the shape
it did: a program the checker accepts must not crash the compiler or
the runtime, so every refusal lands in stage 4 with a sentence naming
the fix — never as a runtime trap, and never as a panic.  A sixth
finding came with them: `==` through a wrapper had been *silently
answering* a question UNION D16 says cannot be asked, which is worse
than the crashes, because nothing said so.

Fixed by one walk (`04_semantics/shapes.zig`'s `incomparablePart`), a
verifier arm over the same rule, and a sweep of sixteen sibling
predicates — of which seven were the same bug and nine were already
correct.  `format_version` did not move: the verifier only got
stricter, and every module it newly rejects is one that could not have
been lowered or could not have run correctly anyway.

---

## 2026-08-12 — release, copy, and harness paths made total

The live inventory found that the runtime's object release, deep copy, and
cross-runtime move still depended on native recursion. `runtime/heap.zig`
now drains an explicit worklist for release and copy. Copy publishes shells
before queuing children so the walk has stable destinations, then rolls back
the root, free-row chain, and grown object-table allocation if a later child
is stale, a resource, or an allocation fails. A 40,000-node release and a
40,000-edge deep-copy test keep those guarantees independent of native stack
depth; list slices and map values use the same copy door.

The executable specification had three false gaps: trap/error census values
were not reported or compared, `prints` accepted matching output after a
non-success ending, and file world comparison omitted handle position and
open-handle state. The callback contract is now ABI version 18, and `agree`
compares those facts on every applicable ending. The host and compiled-run
documentation were updated with the new contract.

The same pass recognized literal infinite loops without breaks as
non-falling-through, made empty-needle counting explicit (`len(s) + 1` byte
boundaries), disclosed floating floor-mod rounding, and added a cross-feature
spec covering a union payload, a bound method, and an optional callback.

## 2026-08-12 — first test-led union and function-value hardening slice

The next pass kept the current borrowing model and attacked its composition
boundary. Differential specs now copy and dispatch optional function values
inside unions, copy union-held bound methods through a container, observe a
receiver mutation through both copies, and unwind through a trapped callback
while a union still owns a payload list.  Runtime coverage adds allocator
failure checks for a function run with a carrying receiver and outside text.

The module seam now also has a hostile-MIR fixture: a bound function with an
out-of-range receiver register and one with a receiver of the wrong type are
both rejected by verification before execution.  The full repository suite
passes with 2,018 tests.
