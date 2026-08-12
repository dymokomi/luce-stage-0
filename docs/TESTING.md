# `luce test`: the test runner

**Status: BUILT — 2026-08-11.**  The design below is as ratified; what
shipped, and every departure from it, is in *As built* at the end.
Direction set in
conversation on 2026-08-10: tests are ordinary Luce in `tests/`
subfolders, driven by `luce test`, asserting with the `assert` the
language already has; the working directory is wherever the command
was typed, like every other `luce` invocation.  A first draft was
adversarially reviewed the same day; its central mechanism (worker
runtimes for per-test isolation) was found structurally unable to
keep its own promise — a worker's trap is final at the join
(THREADS.md D6/T7), so the first failing test would have killed the
run — and the review's replacement is adopted throughout: **the CLI
drives, the artifact answers one test per call.**  It uses strictly
less machinery than the draft did.

The precedent is Zig's: a test is a named block of ordinary code, no
framework, discovered by the tool, passing by finishing and failing
by trapping.  Luce already has every semantic piece — `assert` traps
`assertion_failed` with `file:line:column` and a call trace in debug
builds, a compiled artifact reports a trap through the host's `trap`
channel, and `luce_rt_leaked` answers the census.  What is missing is
discovery, a synthesized entry, and a report — and no new semantic.

## D1. A test is `func test_*()` in an ordinary `.luc` file

```text
import geo

func test_area_of_unit_square():
    assert(geo.area(1.0, 1.0) == 1.0)

func test_open_refuses_missing_file() -> !:
    ...
```

- **Discovery is by name**: every top-level, public, zero-parameter
  `func test_*():` in the file is a test.  Refused by name, never
  skipped: a `test_*` with parameters, inside a struct or enum, with
  a return shape other than nothing or `!` — and a **`private`**
  `test_*`, which would otherwise be a silently-never-run test (the
  diagnostic names the fix: drop `private`, or rename the helper).
  A test that cannot run is a mistake, not an absence.
- **A test file is otherwise an ordinary module**: it imports the
  code under test the ordinary way, obeys the host gate, and may
  define helpers — a helper is any function not named `test_*`.
- **No `main` required or run.**  A test file may have one; `luce
  test` ignores it.

## D2. Invocation: paths in, one report out

```sh
luce test                  # ./tests, the convention
luce test tests/geo_test.luc     # explicit files
luce test tests/geo tests/io     # directories, recursively
```

- Bare `luce test` means the `tests/` directory under the current
  working directory — **the cwd is where the user typed the
  command** — and explicit paths resolve against it, exactly like
  `luce build FILE`.  Directory walks are sorted bytewise, so the
  report order is a property of the tree, not the filesystem.
- No `tests/` and no arguments is a plain failure naming what it
  looked for, not a green "0 tests".  A *named* file with zero
  discovered tests is refused; so is a swept file matching
  `*_test.luc` with zero tests — a file that claims the name and
  delivers no tests is a mistake.  Any other swept file without
  tests is a helper module, skipped, and the summary counts them
  ("2 files without tests") so a wrongly-silent file is one glance
  away.
- **`luce test` takes no build options and always builds debug**:
  the report leans on trap origins, and `--release` would strip
  them.  Unknown options are refused the way `luce build` refuses a
  repeated `-o`.

## D3. Execution: the CLI drives, one runtime per test

- **Anchoring**: a test file compiles with imports anchored at the
  project root (`luce.yaml` discovery, PACKAGES.md D1), so
  `tests/geo_test.luc` importing `geo` reaches the project's `geo`,
  not a phantom `tests/geo.luc`.  Rootless (no `luce.yaml`): the test
  file's own directory, today's rule, and the limitation is reported
  when an import fails ("tests without a luce.yaml resolve imports
  beside the test file").  **This makes `luce test` depend on
  PACKAGES.md step 1**, and the two memos name each other here on
  purpose.
- **The entry is synthesized in a blessed shape.**  Each test file
  compiles once, with a compiler-synthesized
  `func main(args: list(string)) -> !` — the fourth of the four
  entry shapes, the way lambdas are already compiler-synthesized
  functions, so the entry gate stays literally true and gains one
  sentence: no source may declare it.  The entry reads the test
  name from `args` (OWNERSHIP S44's channel, unchanged) and runs
  exactly that test **by direct call** — a static dispatch like the
  worker table, never a runtime list of function values, which the
  type system could not even hold (`func()` and `func() -> !` are
  distinct value types).
- **The CLI calls the artifact once per test**: one `dlopen` per
  file, one `luce_main` call per test, each call a fresh `Runtime` —
  per-test heap, scopes, depth budget, leak census and trap report
  all fall out of machinery that exists.  A trap fails *that call*;
  the loop is in `luce test`, so every failure in the file is
  reported.  Luce has no undefined behaviour to escape a runtime,
  and call depth is policy, so process-per-test buys nothing; this
  is one load per file, stated plainly.
- **The host is the real host** (`src/apps/host.zig`), given to the
  `luce` binary for this command the way loom already wields it —
  including the screen-restore-before-trap-report duty, so a
  full-screen test that traps does not leave the terminal raw, and
  the worker slots, so a test may itself `spawn`.
- Tests run in declaration order within a file, files in sorted
  order; no parallelism in v1.  Parallel *files* later keep this
  surface (per-file output buffered, then flushed in order); a
  scripted-host mode later gets a fresh host per call for free —
  both are reasons for this architecture, not accidents of it.

## D4. The report, and what fails a test

Per file, per test: name, pass/fail, and on failure the rendering
indented under the name.  A test fails by:

- **trap** — rendered as every trap is: code, message,
  `file:line:column`, call trace;
- **raise** — a `-> !` test's error, rendered with its message;
- **leak** — a nonzero per-run census fails the test ("leaked 3
  objects"), because a leaking test is a failing program even when
  its asserts held;
- **`exit`** — a test that calls `exit` fails by name, whatever
  status it chose: a test's job is to return, and an early exit is
  the one way generated code could skip the census.

A file that fails to *compile*, or a discovery refusal, is reported
and makes the run red, and the remaining files still run.  One
summary line — `7 passed, 1 failed, 8 tests in 3 files` — and the
exit status is 0 green, 1 anything else, so a build script needs no
parsing.  Output is the shell palette's when a tty, plain otherwise.
Test stdout is the test's own and passes through, naturally
bracketed by the per-call loop.

## Deliberately absent

- **No assertion library** — `assert(x == y)` with the language's
  own diagnostics.  If bare messages prove thin, the fix is the
  compiler rendering the failing comparison's operands (it has the
  spans), not a matcher DSL.
- **No setup/teardown, no fixtures** — a helper called first thing
  is a fixture; scope ownership already guarantees cleanup.
- **No filtering, tags, or skips in v1** — run a file.  (The
  zero-discovered refusal applies to *discovery*, so a later filter
  flag can answer "no match" in its own gentler words.)
- **No mocking** — the host table is the seam; a scripted host is
  the honest version and waits for a customer.

## Implementation order

1. Discovery + refusals (`apps/luce`): walk, collect `test_*`
   through the front end, refuse the malformed by name.
2. The synthesized `main(args) -> !` entry (compiler), proven to
   round-trip the ordinary pipeline by a spec.
3. The per-call driver loop + host wiring + report + exit status;
   `product.zig` drives a real `tests/` tree end to end, including
   a trapping, a raising, a leaking, and an exiting test.
4. Site: a `luce test` page under the toolchain guide.

Step 1 of PACKAGES.md (project-root anchoring) precedes step 3's
import story for `tests/` directories; it has landed, and `luce test`
anchors on the `luce.yaml` it finds.  A rootless test file whose
compile fails is told the limitation rather than left to guess at it.

---

## As built (2026-08-11)

Built in one vertical, in the order the memo gives.  D1–D4 shipped as
written; the memo left seven things the code had to decide, and each is
here with its forcing reason and where it is proved.

| | decision, and where it is proved |
|---|---|
| **A1** | **Discovery is the runner's, and the compiler is told the answer.**  D1's rules are a *policy about which functions this tool will call*, not a language rule, so `src/apps/luce/discover.zig` decides them over the parsed AST and hands the names down as `luce.types.Entry.tests`.  The forcing reason is D2: the zero-test rules — a named file refused, a `*_test.luc` refused, any other swept file a helper — have to be answered **before** anything is compiled, or a helper module would be compiled to discover that it is a helper and a syntax error in one would fail a run it is not part of.  What keeps this from being knowledge in two places is that the compiler validates the names by *calling* them: a name that does not exist, or is private, or takes a parameter, refuses itself through ordinary name resolution rather than through a second copy of D1. |
| **A2** | **The entry is real AST, not hand-built IR.**  `04_semantics/entry.zig` writes `func main(args: list(string)) -> !` as `ast` nodes in the analyzer's arena and appends the settled signature to the ordinary function table, so the body is checked by `builder.zig`, lowered by `05_hir`, verified, optimized and emitted like any other function.  Hand-building MIR would have meant re-deriving `try`'s error propagation and the ownership of `args` in a second place; this way "round-trips the ordinary pipeline" is not a claim to test but the only path there is.  `specs/testing_spec.zig` runs it on both engines. |
| **A3** | **The dispatch is flat, and every call is spanned at its test's own declaration.**  `if args[0] == "test_x": test_x(); return`, one statement per test, rather than an `elif` chain — a hundred tests would otherwise be a hundred levels of nesting for every later walk to descend.  Each conditional carries the span of the test's `name_span`, so a trap inside a test reports the entry frame at the line the test is written on (`at main (tests/geo_test.luc:10:6)`) rather than at a position nobody wrote. |
| **A4** | **The entry checks the command line it was handed.**  `if len(args) != 1: error(...)` opens the body, and an unmatched name ends it with `error("luce test: no test named " + args[0])`.  Neither can happen when the runner is the caller; both are what the artifact says to a person who ran it by hand, and without the first that person meets `index_bounds` on the next line and reads a trap about the runner's contract as though it were the program's bug. |
| **A5** | **A source `main` is not the entry, and is not merely ignored.**  `is_entry` is computed as `options.entry == .declared and …`, so under `luce test` a declared `main` is an ordinary function: it is not refused, its shape is not checked against the four, and — since nothing calls it — stage 7 drops it before the artifact is written.  `Analyzer.entry_function` is the one field that says which row the runtime starts, filled by whichever of the two rules applied; `checkEntry` moved out of `signatures.zig` into `entry.zig` beside its sibling, so the entry is decided in one file. |
| **A6** | **The whole report goes to standard output, trap renderings included.**  It is one document a person reads top to bottom, and a failing test's trap is part of the report rather than a side channel; splitting it across two streams would make the interleaving of a test's own `print` with its verdict unpredictable.  A test's `print_error` is still its own and still goes to standard error.  `report.printTrap`, `printError` and `printLeaks` gained a leading `indent` — one rendering, positioned by whoever is reporting — and loom and `apps/start.zig` pass `""`. |
| **A7** | **The artifact is written beside the source and removed.**  `tests/geo_test.luc.<pid>-<tid>.test.lc`, deleted when the file's tests are done.  Not `NAME.lc`: that is the name `luce build` writes, and a test runner must not be able to delete a built artifact.  Not the project's `.luce/cache/` either — that is loom's warm-run path, keyed on content for a program that will be run again, and a test artifact is used once by the process that built it.  The name is also **claimed** before it is built (`apps/native.zig`'s `Scratch`): created exclusively, so a file already wearing it stops the run instead of being emptied and then deleted.  `luce test` therefore leaves a directory exactly as it found it. |

Three smaller calls.  `luce.zon` in D3 is `luce.yaml` throughout: that
is what PACKAGES.md D1 shipped as, and the memo was written before it
landed.  `apps/loom/palette.zig` moved up to `apps/palette.zig` with
two styles added (`pass`, `fail`), because whether a stream is a
terminal is one decision and it is not loom's.  And a leaking test is
reported with `report.printLeaks`'s words — "N objects escaped
ownership — please report this" — rather than D4's illustrative
"leaked 3 objects": it is the same fact said once, by the file that
already says it for loom and for a standalone binary, and it asks for
the thing a reader should actually do about an engine bug.

D3's rootless note is conditional, which the memo's "reported when an
import fails" asks for and a naive reading would not have given: it is
printed only when the failure actually named an import.  That is why
`front.compilePath` answers an `Outcome` rather than an optional —
`refused.import_failed` travels as the fact it is, because reading it
back out of the rendered diagnostics would be parsing our own output,
which is the shape this whole design refuses.

**What a leaking test is, and why nothing in the corpus is one.**  D4's
leak arm is real and is checked on every call, but scope ownership
frees everything (OWNERSHIP.md S33), so no Luce source can reach it: it
is a guard against an engine bug, not against a program.  It is proved
where a guard nothing can reach has to be — `suite.verdictOf` is a pure
function from `abi.Status` plus the census plus the exit status to a
verdict, and its unit test reads all six arms including the three
(`leaked`, `exhausted`, `unknown`) that no program can produce.  The
product suite drives the four that a program can: passing, trapping,
raising, and exiting.

**Not built, and still deliberately absent**: everything under
*Deliberately absent* above, unchanged.  Parallel files and a scripted
host remain the two extensions this architecture was chosen to allow,
and neither has a customer yet.
