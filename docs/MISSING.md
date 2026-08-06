# What Luce is still missing — the honest inventory

Rewritten 2026-08-02, after the front-end hardening pass, the `std.`
namespace, the LLVM backend, and `docs/FAILURE.md`.  **Re-verified
line by line against the tree at `f333e12`**, which is where the line
references and corpus counts below now point.  Where a doc and the
code disagree, the code wins and it is said so.

A gap list whose numbers cannot be trusted is still useful and is no
longer *authoritative*, which is the thing it is for.  Every count and
every `file:line` here was re-derived rather than carried forward.

## Scorecard

The **language surface is done.**  Ten conceptual stages, seven
folders, eight executable specs, stages 1 and 2 marked *Locked*, and a
front end whose diagnostics mostly name the fix rather than the
parser's predicament — mostly, because the ownership, optional and
failure families set a standard that fifteen other places do not yet
meet (Tier 5b).  `T?` closed the absence half of the last semantic
hole and `T!` closed the failure half; nothing designed is now
unbuilt.

The **runtime is not done**, but the wall is down.  Tier 0 held two
items, both properties of what existed rather than missing features,
and **both are now closed**: the C-parity backend is reachable from
`loom run` and from `luce build --emit=exe`, and memory is given back
— object identity was reclaimed first, string bytes and struct field
runs second.  A Luce program can run all day.

---

## Tier 0 — ~~the one wall left~~ — **closed**

### 1. ~~Memory is never given back for values~~ — **closed**

`runtime.Memory` still splits storage in two, but the line moved:
`Memory.objects` now holds everything with a death point — container
contents, the object table, **and every string's bytes and every
struct value's field run** — while `Memory.arena` keeps only what a
program cannot grow without bound (a trap's words, the per-layout
struct zero templates, host text on its way into owned storage).

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
`Editing.splice` (`programs/editor.luc:129`) is
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
phase-by-phase measurement).  What is left is the copying itself —
400,001 twelve-byte duplications into list elements — and step 6 is
what removes those.

### 2. ~~The engine that reaches C parity cannot be run~~ — **closed**

It is the only engine now.  **A `.lc` *is* machine code** — the
tagged shared library `luce build` writes — and `loom run FILE.lc` is
one `dlopen`, one symbol lookup and one call.  `--emit=exe` writes a
standalone binary, `--emit=object` a relocatable object, and there is
nothing left to fall back to or select between (docs/ENGINE.md).

What that delivered, measured through `loom run` against the engine
it replaced, while there was still one to measure against: **loops
6995 ms → 92 ms, matmul 5767 ms → 22 ms, strings 931 ms → 57 ms.**  Startup is 3–4 ms and
compiles nothing; compiling is `luce build`'s job and happens when it
is asked for.

The three decisions, all in `docs/CODEGEN.md`: `cc` links, at build
time only, so the *run* path still invokes nothing; a standalone
binary gets **loom's own host**, terminal included, because a
program's behaviour must not depend on who started it; and every
artifact carries an `abi.Artifact` tag — machine, ABI version, a
content hash of the program, and the identity of the code generator —
so a stale or foreign one is refused by name instead of crashing.  The
key is content, never mtime.

What is left of this item is named in docs/ENGINE.md: an artifact is
666–716 KB whatever the program says, because `libluce_rt` is linked
statically into each one, and a shared `libluce_rt` is the named
future optimization; and a `.lc` runs only on the machine that built
it, because cross-compilation needs one `libluce_rt` per target and a
linker willing to take it.

---

## Tier 1 — ~~the semantic hole~~ — **closed**

**Optionals are done.**  `T?`, `none`, narrowing and `else` lower to
`{T, i1}` through LLVM, so a
program that says `T?` is compiled like any other — `parse_int` and
`parse_float` answer `long?`/`double?` and every bundled program that
calls them runs as native code.  What the lowering cost that
`docs/FAILURE.md` did not predict is one refused shortcut, recorded in
docs/CODEGEN.md: the null handle cannot stand in for absence, because
it already names a value that is *there*.

**Errors are done too.**  `T!`, `try`, `catch` and `error(...)` lower
through LLVM as the
outcome word a Luce function already answered, so the success path of
a `try` reads nothing at all.  `T!` really did leave `types.Type`
untouched — fallibility is a bool on `mir.Function`, and not one
`Type` switch grew an arm — which is the one prediction docs/FAILURE.md
made about the cost that survived contact whole.  What it got wrong is
recorded there: ABI 6 rather than 5, `catch` needing a statement form
as well as an expression one, and `file_write` having to become
fallible too, without which the live bug below stayed writable.  The
binding form that memo promised "later" has since landed as `catch
NAME:`, which is the one thing on this page that closed by being
built rather than by being argued away.

The corpus that argued for it, item by item:

- `dice.luc:41` — `if files.write_lines(...)` with **no else**, a
  silently swallowed write failure.  **Fixed, and unwritable**: the
  call answers nothing, so there is no bool to test and no branch to
  forget, and `main() -> !` reports what the disk said.
- `editor.luc`, `wordcount.luc` — `file_exists` then
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

**Still open, and the honest remainder:**

- ~~`wordcount.luc:25` — `counts.has(word)` then index: three hash
  lookups on the hit path.~~ — **settled, and not the way this entry
  expected.**  The counter did not need a `V?`-returning `m.get` at
  all: it needed the language to admit that `counts[word] += 1` is a
  *write*.  A compound store now defines its key at the value type's
  zero (docs/LANGUAGE.md, "Zero values"), the program says one line
  where it said four, and the hit path is two hash lookups.  A plain
  read of an absent key still traps, which is what keeps the `V?`
  question a real one for the cases that are genuinely asking.
- `wordcount.luc:38` — `var best = ""` as "no answer",
  indistinguishable from an empty key.
- ~~11 `trap(...)` calls in `std/math.luc`~~ — **settled.**  The five
  reductions answer `double?`: an empty array has no mean, and that is
  absence rather than failure, so they took `?` and not `!`.  The
  seven left are domains the caller was handed and could have
  checked, which is the rule's definition of a bug.
- `strings.find` returns `-1` because `long?` did not exist.  It does
  now, so the sentinel is a wart with nothing holding it up any more.
  The two-declaration half of this entry is settled: `find_from`
  merged into `find(s, needle, start = 0)` (docs/ARGS.md §9), so there
  is one function and one answer to a `start` outside the string —
  `-1`, an *argument error* the old `find` could never reach.  What
  remains open is the sentinel itself, and the empty-needle
  disagreement with `count` (a match at `start` there, zero here).

---

## Tier 2 — sum types: the absence that keeps bending other designs

**Owner direction, 2026-08-04 — the endgame is set.**  After the
ratified roadmap (named args, visibility, bitwise/hex) come **enums**,
then **union**, "and I think we're good."  Enums lean C: explicit
member values (bytes or numbers) when written, sequential defaults
when not; the design memo brings the backing-type, conversion, and
exhaustive-dispatch questions.  Union's one deciding question —
tagged vs raw — is **ratified: tagged** (owner, 2026-08-04: "Tagged
unions obviously").  A raw overlay would have been an unchecked cast
in a language whose every guarantee assumes values are what they say;
the bits-reinterpretation view (TYPES.md D4) remains the principled
home for genuine raw-overlay needs.  The design memo, when its turn
comes, designs the tagged world: payload-per-member over the enum
machinery, checked access, exhaustive dispatch, and the question of
whether `T?` becomes a two-member tagged union under the hood.


No enums, no tagged unions, no `match`.  This is the second-order
blocker: `docs/FAILURE.md` refuses `Result<T, E>` *because* there are no
tagged unions, which is what forced `T!` to be a function attribute.
Now that it is built, that answer looks better than "probably right":
the attribute is what gave Luce Ok-wrapping for free and kept
`types.Type` out of the feature entirely.  It is still the third design
bent around the same hole.

The corpus pays constantly:

- `editor.luc:361-405` — key handling is one `elif` chain of **15
  string comparisons** with no final `else`.  A misspelled
  `"page_dwon"` compiles and silently does nothing.
- `editor.luc:189` — `# 1 keyword, 2 type name, 3 builtin, 0 plain.`  An
  enum written as a long with a comment.
- `editor.luc:159-187` — `is_keyword`/`is_builtin` as **46 `word == "…"`
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
3. ~~**No receivers on user structs.**~~ **Done** (docs/METHODS.md).
   A function is a method exactly when its first parameter is `self`,
   and `var self` writes the receiver back by copy-in/copy-out.  The
   88 namespaced calls were **not** 88 waiting method calls — they are
   calls on *folders*, and a folder has no receiver; not one function
   in the corpus had the enclosing struct as its first parameter.  The
   harvest was the restructuring the feature permits: `Handle`'s four
   functions and two of `Draw`'s merged into `struct State`, and
   `std/math.luc`'s `list(long)`-as-a-cell workaround became
   `struct Rng`.
4. ~~**No multiple returns.**~~ **Done** (docs/RETURNS.md).
   `-> (A, B)`, `return a, b`, `let low, high = f()`, lowered as a
   compiler-synthesized struct.  `calc.luc`'s `struct Step` is
   deleted, and with it four more disguises of the same missing
   sentence: a heap object as a mutable cell, a second value dropped
   and guessed, a second value thrown away and fetched again, and two
   traversals for one pass.
5. **No sort with a comparator.**  `wordcount.luc:64-73` produces a
   top-5 listing by **destroying the map** — `heaviest` scans, the
   caller prints, `counts.remove(word)`, repeat.  The one place
   no-first-class-functions draws blood.
6. ~~**Host surface gaps**~~ — **mostly closed.**  Nine services
   shipped at ABI 8: `read_line` (with its prompt),
   `print_error`, `clock_ms`, `sleep_ms`, `env`, `file_append`,
   `file_delete`, `file_rename`, `dir_list`, wrapped in `std.files`
   as `append_text`/`append_lines`/`delete`/`rename`/`list`.  The two
   defects this item named are gone: **`calc.luc` is a REPL** (a line
   at a time, a bad expression reported and the loop continuing, a
   blank line or end of input to quit) and **`life.luc` animates**
   (each frame measured with `clock_ms` and the remainder of its
   80 ms waited out, so `sleep_ms` is called with a negative number
   whenever a frame overruns — which is why it is not a trap).

   What was left out, and why:

   - **`exit`.**  Not one builtin.  It is a fourth way for a run to
     end, and every party would need an answer for it: `luce_main`'s
     `Status`, the leak census, what the oracle's frame stack
     does on the way out, and what "scope ownership" means when a
     scope never closes.  `main() -> !` already ends a program early
     with a reason and a status a shell can read, which is what the
     corpus actually wanted.
   - **Path manipulation.**  Not a host gap at all — joining and
     splitting a path is pure text, so it is a std module (`paths`)
     over `strings`, and it should be designed against a program that
     needs it rather than guessed at.
   - **A wall clock and a calendar.**  `clock_ms` is monotonic and
     says only that differences mean something.  Dates are a library,
     not a builtin, and the library does not exist.
   - **Setting an environment variable, and reading the whole
     environment.**  Process-global mutation with no reader in the
     corpus.

   Two things this work found, both recorded rather than papered
   over:

   - ~~**`catch` cannot see the reason.**~~  **Closed** by
     `catch NAME:` (docs/FAILURE.md).  `calc.luc`'s REPL prints the
     parser's own words now, and `editor.luc`'s save reads the
     runtime's rather than writing them a second time.
   - **`files.append` is unwritable.**  `append` is a reserved name
     (it is `xs.append(v)`), and the reservation applies to a
     module-qualified declaration too, so the module reads
     `files.append_text`.  Item 10's visibility run did **not** close
     this: `append` is reserved by the method table, and visibility
     does not unreserve names (docs/VISIBILITY.md §6).
7. ~~**No default or named arguments.**  `term_style(fg, bg, bold)` is
   called 15 times across `programs/`; 14 end in the same noise word
   `false`.~~ — **Closed** (docs/ARGS.md, ratified and built).  Every
   parameter has a name a call site may write, defaults are trailing
   folded constants, struct fields take the same clause, and the
   builtin table carries `term_style(fg, bg = -1, bold = false)` — the
   fifteen sites now write the argument that varies and nothing else.
8. ~~**`Bytes` is unconstructible.**~~  Cut (docs/ENGINE.md step 1):
   `var b: Bytes` compiled, nothing produced one and nothing consumed
   one, and it was one of the two things keeping stage 10 from being
   total.  A real `Bytes` would be designed fresh.
9. ~~**Integer division spelling.**~~  **Closed** by
   docs/NUMERICS.md.  `//` is floor division and `%` is the modulus
   that pairs with it, so both workarounds this item named by line are
   gone: `bf.luc:42` is `(tape[pointer] - 1) % 256`, the spelling its
   author meant, and `math.luc`'s sign-safe parity is
   `long(y) % 2 == 1`.  `/` became real division in the same memo.
10. ~~**No visibility.**  std leaks `is_space_byte` and `fold_case`.
    Cheap, and matters before userland libraries exist.~~ —
    **Closed** (docs/VISIBILITY.md, ratified through three rounds and
    built).  Public by default; `private` in full, per declaration and
    as struct regions; `luce.sema.private` at every resolution site,
    both spellings of the strings leak included; six markers and the
    `math.rng(seed)` factory are the whole migration.
11. ~~**No bitwise operators, no hex literals, no digit separators.**
    Refused by name rather than misread, which is right — but it caps
    what userland can reach.~~ — **Closed** (docs/BITWISE.md, ratified
    and built).  `& | ^ ~ << >>` on the integers at Go's precedence,
    shifts as bit transport with the count checked
    (`shift_out_of_range`), `0xFF`, `0b1010`, `_` separators; octal
    stays refused by name.  What it unblocks is `std.zip` — CRC-32
    and Huffman without division-and-modulo soup.
12. **No codepoint iteration.**  `for c in "abc"` is refused; every
    UTF-8 walk is hand-written, and `editor.luc:53`
    (`Text.continuation`) and `:156` (`Words.continuation_byte`) are
    the same function copied across two namespaces.
13. ~~**`catch` cannot see the reason.**~~  **Closed.**  `CALL catch
    NAME:` binds the error's message to an immutable `string` scoped
    to the handler block, and both callers the item named took it:
    `calc.luc`'s REPL prints what the parser raised instead of the
    line the user typed, and `editor.luc`'s save shows the runtime's
    sentence instead of building its own copy of it.  The binding is
    the message and not the code — a `catch` guards one call and one
    call raises with one code — and not the raise position, which is
    what the report for an error nobody caught is for
    (docs/FAILURE.md's As-shipped note).  The expression form still
    takes no binding, with reasons.
14. **Nothing pins the site's copies of `reserved_names`.**  The
    language's list lives in `04_semantics/context.zig`; the site
    carries it twice, in `site/src/highlight.zig`'s word tables and
    in the block on `/ref/lexical/`, and neither copy is checked
    against the original.  That is how the seven `term_*` builtins
    came to be in the site's "not reserved" list while the analyzer
    dispatched them — the copy was right about the language and the
    language was wrong.  Both are correct now and nothing stops them
    drifting again.  The generator deliberately imports nothing, not
    `luce` and so not libLLVM (`build.zig` says why), so the pin
    cannot be an import; it wants either a generated table checked
    into the site or a test in `luce` that reads the site's text.
    Neither is obviously right, which is why this is written down
    rather than done.
15. **A field of an element needs a `var` root binding.**  `xs[i] = v`
    through a `let`-bound list is ordinary content mutation (S38), and
    `xs[i].field = v` through the same binding is refused — "`xs` is
    let-bound; use var for reassignment" — because the place rule
    walks to the root binding and a nested place rebuilds value
    structs up to it.  Nothing is reassigned: the write lands in the
    container either way.  `programs/world.luc` therefore opens five
    of its methods with `var slots = self.<table>`, an alias declared
    `var` for no reason a reader can see, and the comment there has to
    explain it.  The fix is either to stop at the innermost container
    when the path crosses one (which the assignment rule already
    describes) or to say the restriction out loud in the message; the
    diagnostic naming *reassignment* for a write that is not one is
    the part that misleads.
16. **`assert(x != none)` does not narrow.**  Five shapes narrow and
    they are the right five (docs/LANGUAGE.md), but the first thing a
    person writes above a use is an assertion, and it leaves the name
    a `T?` — so the next line is `luce.sema.absent` and the fix is to
    rewrite the assertion as `if x == none: trap("…")`.  The
    diagnostic names `if` and `else`, which is what saves it; the
    shape itself is still a papercut, and `assert` of a comparison
    with `none` is a narrowing form the flow analysis could read
    exactly as it reads a guard that leaves.

---

## Resolved since the last edition

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
  working** in expressions and constants.  **But adoption is zero**: a
  grep for `ord` across every `.luc` returns no matches, and 54 bare
  character codes remain across four programs.  std's own
  `is_space_byte` still reads `byte == 32 or byte == 9 or …`.  The
  remaining work is a corpus sweep, not a language change.
- **`long.min` writable** — the sign folds before the range check.
- **`1e400` refused** — non-finite float literals are rejected.
- **`not a == b` and `a < b < c` are compile errors**, with messages
  naming both readings.
- **Four-space indentation enforced**; **CRLF sources compile**;
  **bidi controls refused everywhere**.
- **The `std.` namespace** — `import math` binds a sibling, `import
  std.math` binds the library, both together is a collision.
- **Trap locations and call traces**; **runaway recursion traps**
  rather than overflowing the machine's stack.
- **map is O(1)**, open-addressed over insertion-ordered entries.
  **Sort is O(n log n) and stable by guarantee.**
- **Build modes are settled, not pending.**  Luce is always
  `ReleaseSafe`; `--release` is closer to `-fstrip`.
- Also shipped: f-strings, compound assignment, nested place
  assignment, the three std modules, per-stage fuzzing.

---

## Tier 4 — deliberately out of scope, and still right

- **Generics for user code.**  The argument against has strengthened:
  `types.Type` is a closed union with twenty exhaustive switches
  depending on it, and `list(T)` is a monomorphic heap object rather
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
- **Docs to correct:** `tools/vscode-luce/syntaxes/luce.tmLanguage.json`
  is stale — it highlights removed v1 Fabric builtins and knows none of
  `give`, `copy`, `new`, `try`, `catch`, `none`, `import`, or the
  conversion builtins, and its type list has `Input`/`Output` but not
  the four heap types.  `site/src/highlight.zig` is generated from the
  lexer's own keyword table and has a test asserting the two agree; the
  editor grammar should be too, or dropped.  The interpolation
  contradiction in `LANGUAGE.md` and the "future ReleaseFast" in
  `OWNERSHIP.md` are both fixed.  `STD.md` documents sixteen of the
  eighteen functions in `strings.luc`, and the two it omits —
  `fold_case` and `is_space_byte` — are omitted on purpose because
  they are internals; they were *reachable* anyway until item 10's
  visibility run marked them `private`, and now the documentation and
  the compiler say the same thing.

---

## Tier 5b — diagnostics still below the standard the good ones set

The scorecard above calls this "a front end whose diagnostics name the
fix".  That is true of most of them and was written from the ownership,
optional and failure families, which are genuinely excellent — S-numbers,
carets on the offending name, a fix in the sentence, and the advice
keyed to whether the expression was a local (which narrows) or a field
(which does not).  It is not true everywhere, and a hostile-user sweep
of ~110 wrong programs across the lexer, parser and analyzer found the
list below.  Ranked by how often a real program hits them.

**Where it stands after three rounds of work:** twenty-five items
closed, four open, and the four left are the ones a sweep has to look
for rather than trip over.  The families the scorecard was written
from are still the standard; what has changed is that the lexer and
parser now meet it.  Two rules came out of the work and are worth
carrying forward: **one mistake, one report** — which is now a
mechanism (`Lexed.truncated` per file, statement-scoped suppression
per construct) and not a habit — and **check in the order the reader
needs**, after a `try` diagnostic was found giving advice that cost a
signature edit and a recompile to disprove.

**Closed since this list was written.**  The method and built-in
**argument** diagnostics went first — one sentence used to cover both a
wrong count and a wrong type, phrased as a count, with the caret on the
whole call.  Then eleven more, each pinned by a spec asserting code,
wording and column:

- ~~A namespace used without a call denies its own import~~ — and it
  was wider than reported.  `math.seed`, `P.make` and a bare `helper`
  all answered "unknown name" about a declaration the compiler had
  just checked.  Field access on a bare declaration name now resolves
  as a namespace, exactly as it already did in front of a call, and a
  name in value position that names a declaration says what it is:
  *`helper` is a function, and Luce has no function values; write
  `helper(...)` to call it*.  Suggestions come from that namespace's
  own members.
- ~~A mutual struct cycle reports twice, and both messages are
  false~~ — one message per cycle now, walking the loop that closes
  it (*struct A contains itself: A.b is B, and B.a is A*), caret on
  the field rather than the `struct` keyword, and carrying the fix
  `LANGUAGE.md` only ever spelled in prose: `b: B?`.  A spec compiles
  that suggestion, because a message whose fix does not work is worse
  than one that does not help.
- ~~Only the first missing struct field is reported~~ — all of them,
  in declaration order, with the conjunction English wants.
- ~~`script entry must be exactly func main():` is not true~~ — it
  names `func main() -> !:` too, splits the two unrelated mistakes it
  used to answer with one sentence, and points at the return type or
  the parameter rather than at `func main`.
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

**Closed in the round after that**, the six that were ranked here
plus four found while sweeping:

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
  flattening *neither* — the alternative this list proposed — disarms
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

**Still open**, ranked:

1. **`"value %d" % a` is answered as a type error.**  "operands of %
   are string and long, and there is no conversion between them" is
   true, and a reader arriving from Python or C wrote a format string.
   The foreign-operator machinery now in `expressions.zig` is the
   shape of the answer, but this one is a *type* mistake rather than a
   parse one, so it belongs at the `%` type check with the f-string
   named as the fix — and the fix is now a real one to name, since
   `f"{x:.2f}"` exists (docs/NUMERICS.md §8).
2. **A stray `{`/`}` pair is still two reports.**  The typographic
   quote fix pairs on one line; C braces open a block and close it
   several lines later, so the same trick does not reach.  Whether one
   report is even right here is the question to settle first — they
   are two characters on two statements, and the statement-scoped
   cascade rule deliberately lets a second statement speak.
3. ~~**`str takes long, double, bool, string, or builder` does not say
   what it got.**~~  **Closed** by docs/NUMERICS.md, which retired
   `str` for `string(x)`: the constructor's message names the type in
   hand — *"string() converts long, double, bool, or string, not
   list(long)"* — and an f-string hole reports it at the hole.
4. **`give b.items` says "give moves a named object; use copy for
   other expressions".**  A field *is* named, and the real reason is
   that a nested place cannot be moved out of (S21, S25) — the fix
   offered is right, the sentence describing why is not.

**Not a defect, recorded because it looks like one:** `give` through
an alias (`let a = xs; stash(give a)`) compiles and traps
`use_after_free` at run time rather than being refused, while
`free(a)` on the same shape is a compile error.  That asymmetry is
ratified — `OWNERSHIP.md` S23 makes the alias case "the one dynamic
ownership check", and the trap fires correctly with file, line and
column.  The binding's `.alias` class *is* statically known, so a
static refusal is available if the owner wants to revisit S23; it is a
language decision, not a bug to fix quietly.

**Swept with nothing to fix**, so the next sweep can start elsewhere:
the `give`/`copy` family (names the situation, its S-numbers and the
fix at every site tried), method and builtin arity and argument types,
index and slice type mistakes, the rest of the `T!`/`try`/`catch`
family, and `!x`, `//`, `else if`, `def`/`class`/`const`.

**Not a defect, recorded because it looks like one:** `give` through
an alias (`let a = xs; stash(give a)`) compiles and traps
`use_after_free` at run time rather than being refused, while
`free(a)` on the same shape is a compile error.  That asymmetry is
ratified — `OWNERSHIP.md` S23 makes the alias case "the one dynamic
ownership check", and the trap fires correctly with file, line and
column.  The binding's `.alias` class *is* statically known, so a
static refusal is available if the owner wants to revisit S23; it is a
language decision, not a bug to fix quietly.

---

## Tier 6 — the OS beyond the language

Fabric, persistence, braids and sync, capabilities, the agent,
multi-user — all deferred by design in `docs/V2.md`.

---

## The order to work down

1. ~~**Give string storage a reclaimable lifetime**~~ — **done**, and
   so is the **small-string optimisation** that paid for it; see Tier
   0 and step 5 of `docs/STRINGS.md`.  Twenty-two bytes of text live
   in the `Value` that already travels, which cost an `abi.version`
   bump and a `format_version` bump and removed every allocation
   the benchmark's 400,000 `string(i)` results were making.
2. ~~Make the compiled path reachable~~ — **done**; see Tier 0.
3. ~~**`T?`, `none`, narrowing, `else`**~~ — **done**;
   `parse_int` and `parse_float` answer `long?`/`double?`, and a `T?`
   lowers to `{T, i1}`.
4. **The cheap Tier-3 slice:** character classes, and a frozen
   container or `Set`.  ~~`read_line`, `clock`, `sleep`, `env`,
   stderr, directory listing~~ — **done**; see Tier 3
   item 6 for what shipped and what was deliberately left out.
5. ~~**Cut `Bytes`**~~ — done; stage 10 is total.
6. **A `V?`-returning `m.get`**, and sweep the corpus for `ord("x")`
   and f-strings.  (`m.get(key, default)` already exists; what is
   wanted is the overload that can tell a stored `0` from an absent
   one.  ~~Rewrite `wordcount.luc`~~ — **done**, by the zero-value
   rule rather than by this item: docs/LANGUAGE.md, "Zero values".)
7. ~~**Errors** — steps 5–7 of FAILURE.md.~~ **Done.**
8. **Cross-compilation** — `--target`, and one `libluce_rt` per
   target.  Named in `docs/CODEGEN.md` and folded into Tier 0's tail
   without ever reaching this list, which is how the largest
   outstanding backend item came to have no scheduled position.
9. **Share one `libluce_rt` between artifacts** instead of copying it
   into each.  The other one from `docs/CODEGEN.md`, and the reason a
   `.lc` is mostly runtime by size.
10. ~~**Decide receivers and multiple returns**~~ — **done**, one
    memo each and one implementation between them
    (docs/METHODS.md, docs/RETURNS.md).
    Integer-division spelling is decided and shipped
    (docs/NUMERICS.md).
11. **Sum types**, if the `T?` experience says the hole is still there.
12. **Stage 5 (HIR)** — required by `fmt`, by an LSP, and by keeping
    array operations whole.

---

**The honest summary:** the language is complete as designed.  The
front end is in genuinely good shape, and the remaining language work
is one open question (sum types) and a short list of library
functions.  The host surface is closed but for `exit` and paths, and
both were left out with reasons rather than unreached.  The runtime's
outstanding item is not correctness but speed: `strings` is the one
benchmark row still behind its C twin, at **2.73× on the compute
column** (`docs/CODEGEN.md`'s table is the one place that number is
written down).  Small-string optimisation was the queued answer and
**has shipped**; it took roughly three quarters of the cost back and
not the "essentially all" that was predicted, and what is left of the
row is **not yet accounted for** — the element copy it was long
blamed on measures 1.3 ms and cannot be removed anyway, because a
slice is a borrow with no allocation to hand over (`docs/STRINGS.md`).
