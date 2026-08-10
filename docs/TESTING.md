# `luce test`: the test runner (design)

**Status: PROPOSED — nothing below is built.**  Direction set in
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
  project root (`luce.zon` discovery, PACKAGES.md D1), so
  `tests/geo_test.luc` importing `geo` reaches the project's `geo`,
  not a phantom `tests/geo.luc`.  Rootless (no `luce.zon`): the test
  file's own directory, today's rule, and the limitation is reported
  when an import fails ("tests without a luce.zon resolve imports
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
import story for `tests/` directories; until it lands, `luce test`
on a file whose imports live above it reports the limitation rather
than resolving wrongly.
