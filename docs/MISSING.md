# What Luce is still missing — the honest inventory

Rewritten 2026-08-12: **this file is the live inventory and nothing
else.**  What is still missing, broken, refused-but-legal, or below the
standard the good parts set.  Everything that closed moved to
[RESOLVED.md](RESOLVED.md) — a record, ordered chronologically, keeping
the arguments and the measurements that were made once and cannot be
retaken.  Read that one for history; read this one as a to-do list.
Where a doc and the code disagree, the code wins and it is said so.

A gap list whose numbers cannot be trusted is still useful and is no
longer *authoritative*, which is the thing it is for.  Every count and
every `file:line` here was re-derived rather than carried forward, on
2026-08-12, against the tree at that commit.  Line numbers in a file
under active change go stale first; where one no longer resolves, the
name beside it is what to search for.

**Tier 0 and Tier 1 have new occupants.**  Their old ones — the memory
wall, the unrunnable backend, the optional/failure hole — closed and
are in RESOLVED.md.  The tier numbers are ranks, not identities: Tier 0
is what breaks or lies, and the ranking runs down from there.

## Scorecard

The **shipped language core is locked.**  Ten conceptual stages, eight
stage folders (`01_source` .. `08_llvm`), and a front end whose
diagnostics mostly name the fix rather than the parser's predicament.
The serialized module is `format_version` 42 and the published host ABI
is 17.  `T?` closed absence, `T!` closed failure, enums and unions
closed sum types, function values and bound methods closed callable
values, and packages closed *consuming* a library.  One approved
extension is deliberately next rather than silently counted as shipped:
typed channels between workers (`docs/THREADS.md` D12 — and D12
ratifies the **direction only**).

The **runtime is not done.**  Memory is given back and a Luce program
can run all day, which is what Tier 0 used to be about.  What is there
now is smaller and worse-behaved: **a crash on the ordinary release
path** — a scope-end release of a deep enough graph exhausts the native
stack — and **two places a program is handed a wrong number without
being told**.  A language whose whole pitch is that unsafety is
unrepresentable owes those three the top of its own list.

The **executable specification is not as strong as it reads.**  Two
holes in `src/luce/specs/agree.zig` mean a whole class of specs asserts
less than its title: the leak census is skipped on any run that ended
errored or trapped, and `agree.prints` never checks *how* a program
ended.  Tier 1.

The **diagnostics** are in genuinely good shape — three sweeps closed
everything the hostile-user list ranked but three, and the ownership,
optional and failure families are the standard.  The **three** left are
the ones a sweep has to look for rather than trip over (Tier 5b).

---

## Tier 0 — what breaks, and what lies

Three items.  The first is a segfault, and the other two hand a program
a number that is wrong with nothing said about it.  Nothing else in
this document outranks them.

### 1. Ordinary scope-end release of a deep graph segfaults

`src/luce/runtime/heap.zig:2052` (`freeObjectsIn`) → `:1994`
(`freeObject`) → `destroyObject` → `freeValue` → `freeObjectsIn`.  The
release walk is **native recursion with no bound**, so a graph deep
enough to exhaust the C stack takes the process down at scope end.  No
`copy`, no slice, no `map.values()` is involved — this is the death
point every owned thing goes through.

Measured on this host (macOS arm64, the installed ReleaseSafe build) on
a chain of `struct Node: kids: list(Node)`, one child per level:

| depth | main thread | worker thread |
|---|---|---|
| 35,000 | ok | ok |
| 40,000 | **segfault** | **segfault** |

The program prints its result first and dies on the way out, which is
the worst shape a failure can have: the work is done and the exit is a
crash.  The trace is `freeObjectsIn` calling itself past ten thousand
frames.

**This is the one place CLAUDE.md's "call depth is policy, never a
native-stack segfault" is false.**  That promise is about *Luce*
frames, and it is kept: `%depth` rides every generated call and
`call_depth_exceeded` traps at the call that would exhaust it.  The
runtime's own release walk carries no such counter, and neither engine
does — the oracle reaches the same recursion through the same
`libluce_rt`.

The existing note about `copy`, `list_slice` and `map_values`
withholding `willreturn` (RESOLVED.md, the channel prerequisites) named
the *same* hazard on three fresh-allocation paths and did not name this
one.  The fix is the same shape for all four: an explicit worklist in
`heap.zig` instead of the call stack, which is a runtime change with no
language surface and no ABI move.  Anything less — a depth counter that
traps — turns a correct program into a trapping one, which is not what
a release path may do.

### 2. `sin` and `cos` go quietly wrong past about 1e4

`src/luce/std/math.luc:6`, and the source comment argues it in full:
the series are range-reduced with a pi carrying ~20 digits, so each
decade of magnitude past ~1e4 costs a digit — **1e-14 at 1e3 through
8e-3 at 1e15**, measured against libm.  *"Nothing traps: a huge angle
answers a plausible number that is simply wrong."*

It is the one place in the tree a program gets a silently wrong answer
from a function that looks total.  Three ways out and the memo has
picked none: refuse the domain (`double?`, absence past the reduction's
honest range), pay for a two-word or Payne–Hanek reduction, or leave it
and say so on the documentation site next to the function rather than
only in the source.  The current state — argued correctly in a comment
nobody reading `math.sin` will open — is the one option that is not a
decision.

### 3. Floating-point floor-mod can return the divisor

`src/luce/runtime/operators.zig:135`, restated and pinned as a test in
the same file (search `The wart §3 records`): `-1e-100 % 1.0` is exactly `1.0`, because the true answer is a
hair under 1.0 and rounds up.  The invariant `0 <= r < m` a reader
takes from `%` is therefore false in floating point.

**It is argued, and the argument is good**: `%` floors with the integer
one or promotion introduces a discontinuity — `-7 % 3` answering `2`
and `-7 % 3.0` answering `-1.0`, with an invisible widening choosing
between them.  Python has lived with it since 2.0 and
`docs/NUMERICS.md` §3 takes the same trade.  What is missing is that
the wart is **stated in a Zig comment and in nothing a Luce programmer
reads**: neither `docs/NUMERICS.md`'s user-facing text nor the site's
`%` reference says the range can be violated.  A one-sentence
disclosure closes this; a semantic change does not, and should not be
attempted.

---

## Tier 1 — what the executable specification does not actually check

`src/luce/specs/` is the project's strongest claim: every program runs
on both engines and is compared on prints, trap code, trap message,
call trace, **leak census** and the world left behind.  Two of those
comparisons are skipped more often than the sentence suggests.

### 1. The census is not compared on an errored or trapped run

`agree.zig:407` and `:398`.  `settle()` compares status, code, words
and origin for an errored run and returns without touching `leaked`;
the trapped arm does the same.  Only the `ok` and `exited` arms compare
the census (`:425`, `:430`).

The errored arm even argues for itself — *"a run that ended errored
publishes nothing, on either engine"* — and `docs/FAILURE.md:378` is
the reason that argument is backwards: an error *"unwinds **through**
releases, which is the whole difference from a trap."*  An errored run
is precisely the run that must end at zero.  A trap unwinding past
every release (S34) is the other case, where the number is nonzero but
still a fact both engines must agree on.

What it covers: every raising spec.  `agree.errors` has six direct
callers, and two of them are the local `agreeRaises` wrappers —
`src/luce/specs/json_spec.zig:37` with fourteen call sites and
`src/luce/specs/zip_spec.zig:33` with eleven — plus
`threads_spec.zig:386`, `std_spec.zig:781` and `:794`, and
`behavior_spec.zig:5702`.  **That last one is the sharpest case**:
`behavior_spec.zig:5689` is titled *"a call that raises leaves nothing
where its value would have gone"* and is a regression test for a
failure-path memory bug found in `std.zip` — a raising call handing a
freed struct run to the release at frame end.  It is the exact test
whose census would catch a regression, and the census is off.

### 2. `agree.prints` never checks how the program ended

`agree.zig:619`.  It runs `compare` — which does make the two engines
agree with each other about the ending — and then asserts the
transcript alone.  So **a program that prints the right bytes and then
traps passes**, as long as it traps identically on both arms.

`threads_spec.zig:270, 288, 301, 316, 334, 344` are all `prints`
assertions *about termination and release* — an unwaited task joining
at scope end, `free` as an early join, a task returned and waited on
elsewhere, tasks joined in list order — and the transcript is the only
thing being checked.

The clearest instance is `threads_spec.zig:547`, titled **"a worker
that leaks is counted in this program's census"**.  Its body asserts
`session.end.trapped == divide_by_zero` and never reads `leaked` — and
cannot, because item 1 above means the trapped path never populated a
comparison to read.  The test's title states a claim the test does not
make.

**The fix is one shape for both.**  Give `settle()` the census on every
arm, and give the `prints` family an ending to assert (or a sibling
that takes one).  Both are test-harness changes with no compiler or
runtime surface; both will fail some specs when they land, and those
failures are the point.

### 3. The dual-engine world does not compare file-handle state

`agree.zig:439` (`sameWorld`) compares the file's name and content,
`keys_read`, `lines_read`, `clock`, `epoch` and the directories made —
but not `handle_position`, and not which handles remain open.  A
one-engine file effect can evade the world comparison.  The constant
`file.read` immutability spec pins `handle_position == 0` explicitly,
which is the workaround; comparing all file-handle state generically is
the fix (audit F51).

---

## Tier 2 — the one approved language extension left

**Typed channels between worker runtimes.**  Workers and owned `task`
joins are built, the two-runtime transfer primitive is transactional,
and the six channel prerequisites are closed (RESOLVED.md).
`docs/THREADS.md` D12 reserves typed channels whose `send(give x)`
transfers ownership between runtimes.

**D12 ratifies the direction and nothing more.**  The channel type,
buffering and back-pressure, what a receive answers, close behaviour
and the failure surface all still need an owner decision, and no line
of it is designed.  Counting this as "next" is honest; counting it as
"nearly there" is not.

Everything else on the ratified language roadmap is worked down.  Two
consequences of the features that landed are the live remainders:

- **A fallible function type does not exist.**  `func(T) -> R!` is
  refused, so a fallible function is not a value and a fallible method
  does not bind (`docs/BINDING.md` D8, the one outstanding decision in
  that memo; its third *As built* carries the step-by-step remainder).
- **The owning bind stays refused.**  `give counter.bump` would make a
  function value the sole owner of a graph, and a handler-holding
  struct would become object-carrying, so `let b = a` would silently
  alias where it copies today.  Per-value tracking (the
  `nodes.provenance` shape) is the named reopening path if a customer
  ever bleeds for it.

---

## Tier 3 — what a real program actually hits

Read from `examples/`, `packages/` and the standard library for
awkwardness rather than features.

1. **A loop never guarantees a return.**
   `src/luce/04_semantics/helpers.zig:377` (`returnsOnAllPaths`) is
   conservative by construction — *"Loops never guarantee a return"* —
   so a function whose every exit is a `return` inside `while true:` is
   refused:

   > `pick must return long on every path, and some path reaches the
   > end of its body without returning`

   The same refusal catches any function whose last statement is a call
   to something that never comes back: `leavesByCall` (`helpers.zig:366`)
   recognises **only** the literal names `trap`, `error` and `exit`, so
   a user `die(message)` that ends in `trap` does not count.

   Retry loops, REPL loops, event loops and state machines are the
   common idiom this refuses, and the workaround — a dead `return 0`
   after the loop — is exactly the misleading dead code the
   unreachable-code diagnostic was added to refuse in the other
   direction.  Two
   independent fixes: recognise `while true:` with no `break` as a
   non-returning statement, and infer "never returns" for a user
   function the way "writes its receiver" is already inferred
   transitively (`04_semantics/receiver.zig` is the precedent).
   Refused-but-legal, and the most likely of these to be hit by
   somebody's first real program.

2. **`\r` and `\u{…}` are refused.**  `src/luce/02_lex/lexer.zig:111`
   calls both *"defensible additions"* and says why neither is here:
   the lexer only validates an escape and `03_parse`'s `decodeString`
   produces the bytes, so adding one on this side alone would silently
   produce wrong text.  The escape set moves as one change across two
   stages or not at all.  (`\xNN` is refused permanently and for a
   different reason: a raw byte escape can build a string that is not
   UTF-8, and every other layer is allowed to assume it is.)

3. **No codepoint iteration in the language.**  `for c in "abc"` is
   refused — *"for iterates a list, a rank-1 array, or a map, not
   string"*.  The library half is closed: `strings.characters(s)` hands
   back the code points and `strings.width`/`strings.take` measure and
   clip by them, so `for c in s.characters()` is the walk a program
   writes today.  What is left is the loop form itself, an iteration
   that allocates no list.

4. **The corpus still carries a workaround the compiler stopped
   needing.**  `examples/adventure/world.luc:304` explains, in a
   comment addressed to the reader, why seven of its methods open with
   `var slots = self.<table>`: *"assigning to a field of an element
   needs a place whose root binding is a `var` … it is the one place
   this program has to say something to the compiler rather than to the
   reader."*  **That restriction is gone** — `self.rooms[at].seen =
   true` compiles, and so does `xs[0].n = 2` through a `let`-bound list
   (RESOLVED.md, 2026-08-12).  The seven aliases and the paragraph
   defending them are now the misleading thing.  A sweep, not a fix.

5. **`assert(x != none)` does not narrow.**  Five shapes narrow and
   they are the right five (`docs/LANGUAGE.md`), but the first thing a
   person writes above a use is an assertion, and it leaves the name a
   `T?` — the next line is `luce.sema.absent` and the fix is to rewrite
   the assertion as `if x == none: trap("…")`.  The diagnostic names
   `if` and `else`, which is what saves it.  `assert` of a comparison
   with `none` is a narrowing form the flow analysis could read exactly
   as it reads a guard that leaves.

6. **`strings.find` and `strings.count` disagree about an empty
   needle.**  `find(s, "", start)` answers `start`
   (`src/luce/std/strings.luc:33`); `count(s, "")` answers `0`
   (`:67`).  Both are defensible alone and they cannot both be right in
   one module.

7. **`files.append` is unwritable.**  `append` is reserved by the
   list-method table, and the reservation applies to a module-qualified
   declaration too, so `src/luce/std/files.luc` reads `append_text`,
   `append_lines`, `append_to` and `append_bytes`.  Visibility did not
   unreserve it (`docs/VISIBILITY.md` §6) and nothing else will.

8. **`var best = ""` as "no answer".**  `examples/wordcount/wordcount.luc:38`
   still uses the empty string to mean "nothing found yet", which is
   indistinguishable from an empty key.  `string?` exists; the program
   predates it.

9. **There is still no `set(T)`,** deliberately.  A constant
   `map(T, bool)` covers every caller in the corpus — the editor's
   three highlighting tables (`editor.luc:258`, `:274`, `:281`) — so a
   fifth heap type and a second brace meaning have no corpus pressure
   behind them.  Add one when a constant map stops answering, and not
   before.

10. **Arrays have no slice expression.**  `a[0:2]` on an
    `array(long, _)` is refused naming `list` and `string` as what
    slices.  A constant list may be sliced and the result is a fresh
    owned list; constant arrays, like ordinary arrays, support
    indexing, iteration and `copy` only (audit F49).

11. **Setting an environment variable, and reading the whole
    environment.**  `env(name)` reads one; process-global mutation has
    no reader in the corpus and is not built.

12. **There is no calendar.**  `epoch_ms` is milliseconds since the
    Unix epoch and is the number a date library will be built on.  The
    library does not exist.

13. **Whitespace immediately inside an f-string hole is rejected.**
    `f"{ value }"` is `luce.parse.fstring`, *"malformed expression in
    f-string"*: a hole is re-lexed as a standalone buffer, where the
    leading space is mistaken for indentation.  Nested map braces in a
    hole work.  Trimming, or offset-aware hole lexing, is the parser
    improvement (audit F17).

---

## Tier 4 — deliberately out of scope, and still right

- **Generics for user code.**  The argument against has strengthened:
  `types.Type` is a closed union with twenty exhaustive switches
  depending on it, and `list(T)` is a monomorphic heap object rather
  than a generic.  `T?` did become a variant of `Type` — one, whose
  payload is a union of its own so `T??` is unrepresentable — and it
  opened no door at all: nothing about it generalizes.  Function values
  and unions have since shipped, and neither is a type parameter.  The
  closed specialization used by `std.lists.sort_by` is compiler-owned
  std machinery, not a surface generic system.
- **Closures — absent, and answered.**  Function values, one-expression
  lambdas and bound methods shipped on the near side of the capture
  line, and `receiver.method` made the answer literal: the environment
  is a struct the program declared.  Nothing anonymous entered the
  language, and nothing will (`docs/BINDING.md`).
- **Iterators.**  What is missing is not a protocol but string
  codepoints — one loop form, Tier 3 item 3.
- **Interfaces, inheritance, operator overloading, async, reflection.**
  No.
- **`defer`** — superseded by scope ownership.  Zig removed capturing
  `errdefer` in April 2026; Luce needs neither.
- **Locks, atomics, shared mutable state, thread identifiers,
  `async`/`await` colouring.**  Permanently absent: the ownership model
  is the concurrency model (`docs/THREADS.md`).

---

## Tier 5 — stage and tooling distance

### The pipeline

- **Two desugarings are still upstream of the typed tree.**
  `03_parse` expands f-strings into `string(x) + …` and `elif` chains
  into nested `if`s while it still has nothing but syntax
  (`03_parse/ast.zig:294`, `03_parse/expressions.zig`), so those two
  arrive at stage 5 pre-expanded.  Moving them down changes stage 3's
  output and is its own landing.
- **Whole-array operations must survive stage 5 as single nodes**, and
  today they do not reach it as such: `std.math`'s BLAS-1 functions are
  already scalar loops by the time MIR exists, and LLVM 22 fuses
  adjacent elementwise loops under *no* configuration of `-O3`.  That
  is a performance item decided in a language stage, and it cannot be
  taken back.  The warning is written at the top of `05_hir/lower.zig`;
  what is missing is a customer and a node.
- **The final-MIR program-root proof is conservative beyond
  `heap_new`.**  Every other heap-producing instruction starts as
  may-root, so fresh runtime operations such as `copy`, a list slice,
  or map `keys()`/`values()` can retain an unnecessary inline owner
  guard after local flow.  The full benchmark A/B is flat.  A future
  whitelist belongs behind runtime-contract tests and the same
  hostile-MIR proof, not behind assumptions in lowering (audit F61).
- **Function pruning can retain an otherwise dead function through an
  orphan `const_function`.**  It scans a reachable function's raw
  instruction pool conservatively rather than only surviving block
  items.  This changes artifact size, not behavior (audit F22).
- **Verified MIR can carry an empty constant-map pool row.**  Source
  `{}` is deliberately refused because it supplies neither key nor
  value type, but a decoded module may name both in its heap row and
  provide zero entries.  Materializing that row is safe; whether the
  wire should reject every source-impossible constant shape is a
  verifier canonicalization question (audit F75).
- **LLVM materialization of a constant array of value structs first
  fills every cell with the zero struct, then replaces every cell with
  its folded value.**  The stable array API makes this cleanup-safe and
  correct; a bulk constructor could remove the duplicate storage work
  if startup measurements justify one (audit F40).

### Code that would answer dishonestly if it were ever reached

- **`src/luce/08_llvm/lower.zig:6235`** lowers `==`/`!=` on a function
  value by comparing `namedFunction(left)` against
  `namedFunction(right)` — the *function index only*, ignoring the
  receiver slot beside it.  That is exactly the dishonest answer
  `docs/BINDING.md` D6 refuses: two values of one method with different
  receivers would compare equal.  It is unreachable today because stage
  4 refuses first, with D6's own sentence.  The comment above it at
  `:6208` still cites `docs/FUNCTIONS.md` D3, which D6 retired.  Delete
  the arm and let the operand-type switch reach `.unsupported`, which is
  what the stage's own rule prescribes for IR that could only arrive
  damaged.

- **A routed string method's arguments land on nothing.**
  `04_semantics/calls.zig:2145` says it plainly: *"the batch landed its
  arguments from the receiver, not from strings' declaration, so a
  reordered literal would land at the wrong width."*  `s.split(",")`
  becomes `strings.split(s, ",")` **after** the operand batch has
  already been typed, so no argument of a routed method takes its type
  from the target's declaration.  The stage copes by refusing named
  arguments on the routed spelling and telling the reader to write
  `strings.split(…)` instead.  Harmless today because every non-receiver
  parameter in `src/luce/std/strings.luc` is a `string` or a `long`,
  where the default landing happens to agree.  It goes live the day one
  takes a `byte`, a `double`, an optional or a function value — which
  `to_bytes`/`from_bytes` already sit next to.

### Tools

- **`luce ir` prints a constant container's enum members as raw
  numbers.**  `const table: map(Key, Intent) = {Key.up: Intent.move,
  Key.down: Intent.quit}` dumps as
  `constant container#0 table: map(Key, Intent) = {0: 0, 1: 1}`, and a
  `const kinds: list(Intent)` as `[0, 1]`.  The header names the types
  and the payload ignores them: `06_mir/print.zig:142`
  (`printConstantValue`) walks a `ConstantValue` with no type in hand,
  while the struct printer beside it already resolves field names.
  Lists, maps and arrays are all affected.  A reader cannot check a
  constant table by eye, which is the one thing `luce ir` is for.
- **No `luce fmt`, no LSP, no debugger.**  `fmt` and an LSP both wanted
  stage 5's faithful tree first and now have it; what is left for them
  is the tooling itself.
- **Packages: producing and fetching are not built.**  Consuming is
  (`docs/PACKAGES.md`, ratified and built, five steps).  What remains
  is everything that *makes and moves* a package: `luce install` /
  `luce update` / `luce init`, the registry and its static-file fetch
  protocol, publishing manifests with mandatory hashes, signatures and
  yanking, the package export boundary, and `std.yaml` — each a named
  deferral in that memo, waiting on the publishing memo it says comes
  next.  Until then a package enters a project by being copied into the
  store, which is vendoring, and is proven end to end by
  `packages/termui-0.1.0/`.
- **Cross-compilation.**  No `--target`: a `.lc` runs only on the
  machine that built it, because cross-compiling needs one
  `libluce_rt` per target and a linker willing to take it.
- **`libluce_rt` is copied into every artifact.**  An artifact is
  mostly the runtime by size, so what a program *says* barely moves the
  number: in the install tree on 2026-08-12, `hello.lc` is 796 KB and
  the largest bundled program, `editor.lc`, is 1,008 KB — a 26% spread
  across every program in the corpus.  Sharing one `libluce_rt` between
  artifacts is the named future optimization (`docs/ENGINE.md`).
- **VS Code's word-free colon indentation is not brace-aware.**  The
  language suspends layout inside braces, so a map entry may legally
  put its value on the line after `"key":`.  The extension's `:\s*$`
  rule treats that colon like a block opener, overindents the value and
  cannot know to return for the next key.  A real fix needs brace-aware
  editor state rather than another one-line regex; the extension README
  states the approximation (audit F73).
- **The site and generated TextMate highlighters only approximate
  f-string holes.**  The compiler accepts a nested string or nested map
  braces inside one, but the TextMate hole region does not recursively
  enter strings or balance braces, while the site's single-string scan
  stops at the inner quote.  Highlighting can therefore end early.  The
  generator, highlighter and extension README no longer misstate that
  tooling limitation as a language restriction; recursive hole-aware
  scanning remains editor work (audit F54).

### Documentation that is wrong right now

Each of these is a sentence in the tree that a reader would be
misled by, verified against the code on 2026-08-12.

- **`src/luce/std/os.luc:204` is stale.**  `cpu_count()` carries *"Luce
  has no threads, so this is a fact to report and not yet a fact to act
  on."*  Workers shipped (`docs/THREADS.md`), and the processor count is
  exactly the number to size a pool of them with.  The sentence below it
  — that the number was added early to avoid an ABI bump later — is
  still true and should stay.
- **`src/luce/std/math.luc:164` contradicts its own specs.**  The
  section comment says *"the operations that have no empty answer
  (mean, vmin, vmax, variance) trap"*.  They do not: all four answer
  `double?` and return `none` (`:176`, `:181`, `:189`, `:225`), which
  the comment eight lines further down (`:172`) says correctly.
  `src/luce/specs/std_spec.zig:210` and `docs/STD.md:833` both document
  the `?`.
- **`docs/STD.md:193` promises what `:233` retracts.**  The API table
  says `strings.width(s)` answers *"long — display cells"*; the
  limitation section says *"v0.1 counts code points, not terminal
  cells"* — `width("日本")` is 2 where a terminal draws 4.  The
  retraction is documented and pinned by `std_spec`; the table line
  contradicting it is not.
- **The reserved-name roster on `/ref/lexical/` has already drifted.**
  This document warned that it could and it has:
  `src/luce/04_semantics/context.zig:217` lists **61** reserved names
  and `www/luce/content/ref/lexical.md:138` lists **60** — the block is
  missing `term_event_data`.  `www/luce/src/coverage.zig:346` does read
  the roster from `context.zig`, but for *highlighting* coverage; the
  page's code block is a hand copy nothing compares.  The generator
  deliberately imports nothing, not `luce` and so not libLLVM
  (`build.zig` says why), so the fix is a source-derived generated table
  checked into the site, or a test that reads the roster back out of the
  rendered page (audit F52).
- **The editor mirrors the compiler's word vocabulary by hand, and it
  has drifted again.**  `examples/editor/editor.luc:258`, `:274` and
  `:281` are three immutable `map(string, bool)` constants — keywords,
  type names, builtins — and the comment above them names the ground
  truth they were copied from: `02_lex/token.zig`'s `keywords` and
  `04_semantics/builtins.zig`'s `builtins`.  Nothing derives or checks
  the copy.  **`keyword_words` holds 33 words and `token.zig` holds
  34**: `union` shipped on 2026-08-10 and the editor does not colour
  it, and the comment still says "thirty-three words" because that was
  true when it was written.  The last drift was eight language
  generations wide; this one is two days.  The generated VS Code
  grammar does not solve it — that is Zig reading Zig, and this is
  Luce.  Two hand copies of one roster now disagree with each other as
  well as with the source: the editor's builtin table carries
  `term_event_data` and `/ref/lexical/`'s reserved block does not.
- **Four stable trap messages retain pre-resource vocabulary.**
  `use_after_free`, `null_object`, and defense-only `not_owned` use
  "object" in the runtime's broad heap-handle sense, so they can also
  describe `file` or `task`; `allocation_failed` says "container" even
  when allocating a file/task resource row failed.  The site explains
  the broad legacy term.  Decide whether to keep that ABI-like
  diagnostic stability or migrate all four together; do not change one
  opportunistically.
- **S6's early-release wording is broader than its current surface.**
  `free(x)` accepts an owned container handle, `file`, or `task`, but a
  struct that carries one of those is rejected by the builtin's heap
  type gate even though its binding participates in ownership and dies
  correctly at scope end.  Decide whether S6 means direct heap/resource
  handles only, or whether explicit early release should walk a carrying
  struct; do not imply either answer by accident in a diagnostic.
- **Flatness is an implementation boundary as well as a language
  decision.**  If nested constant containers are admitted later, the
  program-root census and teardown must count and sweep child rows, and
  `copy` plus mutable-container adoption need the recursive ownership
  rule.  Relaxing flatness is source-compatible, but it is not merely
  deleting the front-end refusal.

### Test-harness debts smaller than Tier 1's

- **Interpreter-worker arena exhaustion may be reported as
  `host_unavailable`.**  The worker can reach trap adoption without a
  pending runtime trap, and the fallback names the host instead of the
  allocator.  This affects the differential oracle's failure
  translation, not compiled program semantics (audit F30).
- **The release-mode differential harness strips origins twice.**  The
  operation is idempotent, so this is redundant test work rather than a
  semantic defect (audit F35).
- **An unimported loaded namespace has two diagnostics.**  Calling a
  name through it reports `luce.sema.import` and teaches `import X`,
  while the same dotted value or constant read falls through to
  `luce.sema.name` as `unknown name X`.  Unifying field and value
  namespace diagnostics remains follow-up work (audit F72).

---

## Tier 5b — diagnostics still below the standard the good ones set

The scorecard calls this "a front end whose diagnostics name the fix".
That is true of most of them and was written from the ownership,
optional and failure families, which are genuinely excellent —
S-numbers, carets on the offending name, a fix in the sentence, and the
advice keyed to whether the expression was a local (which narrows) or a
field (which does not).

A hostile-user sweep of ~110 wrong programs across the lexer, parser
and analyzer produced the ranked list, and three rounds of work closed
every item on it but three; the ledger and the two rules that came out
of it are in RESOLVED.md.  The **three left** are below, ranked, each
re-checked against the installed compiler on 2026-08-12:

1. **`"value %d" % a` is answered as a type error.**  The message —
   *"operands of % are string and long, and there is no conversion
   between them"* — is true, and a reader arriving from Python or C
   wrote a format string.  The foreign-operator machinery in
   `03_parse/expressions.zig:223` is the shape of the answer, but this
   one is a *type* mistake rather than a parse one, so it belongs at the
   `%` type check with the f-string named as the fix — and the fix is
   now a real one to name, since `f"{x:.2f}"` exists
   (`docs/NUMERICS.md` §8).

2. **A statement-level `{` is read as a map literal, and the diagnostic
   lands on the wrong brace.**  A bare C-style block —

   ```text
   while n < 3:
       n += 1
   {
       print(string(n))
   }
   ```

   — reports at the *closing* brace, *"expected ':' between a map key
   and value, found '}'"*.  One report, which is the improvement the
   last round made, but it names maps to a reader who wrote a block.
   **The "still two reports" half of this entry no longer
   reproduces**: four shapes were tried on 2026-08-12 (a C-style `func
   main() { }`, a C-style `if`/`else`, a stray closing brace at file
   scope, and the block above) and each gave exactly one diagnostic.
   What is left is the wording, not the count.

3. **Ownership advice is not whole-batch-aware at every adopting
   surface.**  `[running, running]` correctly fails on the first bare
   name and advises *"write give running to hand it over, or copy
   running to keep your own"*; applying that edit poisons the later
   occurrence.  The original programs are refused and no invalid
   ownership reaches MIR — this is diagnostic precision only.  A future
   pass should inspect the complete operand batch before prescribing a
   move, across user calls, constructions and retaining literals, and
   either name the later use or recommend splitting the operation.

**Swept with nothing to fix**, so the next sweep can start elsewhere:
the `give`/`copy` family (names the situation, its S-numbers and the
fix at every site tried), method and builtin arity and argument types,
index and slice type mistakes, the rest of the `T!`/`try`/`catch`
family, and `!x`, `//`, `else if`, `def`/`class`/`const`.

---

## Tier 6 — the OS beyond the language

Fabric, persistence, braids and sync, capabilities, the agent,
multi-user — all deferred by design in `docs/V2.md`.

---

## Open questions for the owner

Not defects.  Each is a place where the language behaves as designed
and the design has a live question in it.

- **`string(f)` on a bare function name is refused while `string(f)` on
  a binding works.**  `let f: func(long) -> long = a` then `string(f)`
  answers the function's name; `string(a)` on the declaration itself
  reports *"a is a function; write a(...) to call it, or annotate the
  place it goes with the function type it should wear"*.  The reason is
  structural: `string()`'s parameter is polymorphic, so nothing at that
  call site names a function type for the bare name to land on.  Making
  it work means typing a function value from its *declaration* rather
  than from its landing place, which `docs/FUNCTIONS.md` D2 refuses on
  purpose.  So the choice is: leave it (and the diagnostic is already
  good), special-case `string()` to accept a declaration name, or
  reopen D2.  An owner decision, not a bug report.
- **`sin`/`cos` past 1e4** — Tier 0 item 2 states the defect; which of
  the three exits to take is a decision nobody has made.
- **Floating-point floor-mod** — Tier 0 item 3; the semantics are ratified and
  only the disclosure is missing, but *where* to disclose it is the
  owner's call.

---

## The order to work down

1. **The release-path stack overflow** (Tier 0 item 1).  It is on the
   path every owned thing takes, it is a segfault rather than a trap,
   and the fix — an explicit worklist in `runtime/heap.zig` — has no
   language surface and no ABI move.  The same change should take `copy`, `list_slice` and
   `map_values` off the same recursion.
2. **The two specification holes** (Tier 1 items 1 and 2).  Cheap, and
   everything after this is measured by a suite that is currently
   allowed to miss a leak on the failure path and a trap after correct
   output.  Landing them will fail some specs; that is the point, and it
   is better to learn it now than after a channel run.
3. **The two silently wrong answers** (Tier 0 items 2 and 3).  Item 3
   is a documentation sentence.  Item 2 is a real decision with three
   named exits.
4. **A loop that returns on every path** (Tier 3 item 1).  The most
   likely refusal for somebody's first real program, and the fix is two
   contained changes to `04_semantics/helpers.zig` with an existing
   precedent for the harder half.
5. **Typed channels** — the approved next design-and-implementation
   run.  `docs/THREADS.md` D12 ratifies the ownership-moving
   `send(give x)` direction only; the channel type, capacity, receive
   and close behaviour and the failure surface all remain to be
   ratified, so this is a memo before it is a branch.
6. **Publishing packages** — the memo `docs/PACKAGES.md` says comes
   next: `luce install`, the registry, manifests with mandatory hashes,
   signatures, the export boundary, `std.yaml`.  Consuming is built and
   `termui` 0.1.0 proves it end to end by vendoring; nothing can be
   moved between machines yet.
7. **Cross-compilation** — `--target`, and one `libluce_rt` per target.
8. **Share one `libluce_rt` between artifacts** instead of copying it
   into each.

---

**The honest summary:** the shipped core is locked, the ratified
language roadmap is worked down, and the front end is in genuinely good
shape.  What is left is smaller and sharper than what came before it.
A segfault on the ordinary release path, in a language that promises a
native-stack segfault is unrepresentable.  Two silently wrong answers,
one of them ratified and merely undisclosed.  A specification whose
failure-path arm does not check the two things it advertises.  Typed
channels are the approved next design run and are a memo away from
being one.  Packages can be consumed and not published.  **Four**
benchmark rows remain behind their C twins — `strings` 2.75x, `lists`
2.53x, `arrays32` 7.92x and `stats` 1.32x on the floor-subtracted
compute column — for four different reasons; `docs/CODEGEN.md` is the
one current table and the one place their ratios are written, and the
remaining part of the `strings` row is still not accounted for
(`docs/STRINGS.md`).
