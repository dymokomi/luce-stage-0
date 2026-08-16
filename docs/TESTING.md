# `luce test`: the test runner

`luce test` runs the project's tests. A test is a named block of
ordinary Luce code — no framework, no assertion library — discovered by
the tool, passing by finishing and failing by trapping. The precedent
is Zig's, and Luce already has every semantic piece it needs: `assert`
traps `assertion_failed` with `file:line:column` and a call trace in
debug builds, a compiled artifact reports a trap through the host's
`trap` channel, and the runtime answers a leak census. What `luce test`
adds is only discovery, a synthesized entry, and a report.

## A test is `func test_*()` in an ordinary `.luc` file

A test is a **top-level, public, zero-parameter `func test_*()`** whose
return shape is nothing or `!`:

```text
import geo

func test_area_of_unit_square():
    assert(geo.area(1.0, 1.0) == 1.0)

func test_open_refuses_missing_file() -> !:
    ...
```

- **Discovery is by name.** Every top-level, public, zero-parameter
  `func test_*()` in the file is a test.
- **A malformed `test_*` is refused by name, never silently skipped.**
  A `test_*` that takes parameters, sits inside a `struct`/`enum`/
  `union`, or answers a value other than nothing or `!` is refused, and
  so — above all — is a **`private`** `test_*`, which would otherwise be
  a test that never ran. Each refusal names its `path:line:column` and
  the fix (for a private one: drop `private`, or rename the helper). A
  test that cannot run is a mistake, not an absence.
- **A test file is otherwise an ordinary module.** It imports the code
  under test the ordinary way, obeys the host gate, and may define
  helpers — a helper is any function not named `test_*`.
- **A `main` is neither required nor run.** A test file may declare one;
  `luce test` treats it as an ordinary function and, since nothing calls
  it, drops it before the artifact is written.

## Invocation: paths in, one report out

```text
luce test                        # ./tests, the convention
luce test tests/geo_test.luc     # explicit files
luce test tests/geo tests/io     # directories, recursively
```

- Bare `luce test` means the `tests/` directory under the current
  working directory — the cwd is wherever the command was typed, exactly
  as `luce build FILE` resolves. No `tests/` and no arguments is a plain
  failure naming what it looked for, never a green "0 tests".
- Named files are taken as written; directories are walked recursively
  for `*.luc`, **sorted bytewise at every level**, so the report order
  is a property of the tree rather than of the filesystem. Entries
  beginning with a dot are left alone, so a `.luce/cache` of artifacts
  is never mistaken for a suite.
- A **named** file with zero discovered tests is refused; so is a swept
  file matching `*_test.luc` with zero tests — a file that claims the
  name and delivers none is a mistake. Any other swept file without
  tests is a helper module, skipped, and counted in the summary
  ("2 files without tests") so a wrongly-silent file is one glance away.
- `luce test` takes **no build options and always builds debug**,
  because the report leans on trap origins and `--release` would strip
  them. An unknown option is refused the way `luce build` refuses a
  repeated `-o`.

## Execution: the CLI drives, one runtime per test

Discovery is the runner's job, not the compiler's. `luce test` reads
each file's AST, decides which functions are tests, and hands the names
to the compiler as the entry to synthesize. The zero-test rules above
are answered *before* anything is compiled — otherwise a helper module
would be compiled only to discover that it is a helper, and a syntax
error in one would fail a run it is not part of. What keeps "what is a
test" from living in two places is that the compiler validates the names
by *calling* them: a name that does not exist, or is private, or takes a
parameter, refuses itself through ordinary name resolution.

- **Anchoring.** A test file compiles with imports anchored at the
  project root (`luce.yaml` discovery, `docs/PACKAGES.md`), so
  `tests/geo_test.luc` importing `geo` reaches the project's `geo`, not
  a phantom `tests/geo.luc`. Without a `luce.yaml`, imports resolve
  beside the test file, and that limitation is reported when an import
  actually fails.
- **The entry is synthesized.** Each test file compiles once with a
  compiler-written `func main(args: list[str]) -> !` — the fourth of
  the four entry shapes, built as real AST and checked, lowered,
  verified, optimized and emitted like any other function, so no source
  may declare it. The entry reads the test name from `args` and runs
  exactly that test **by direct call** — a static dispatch, one `if
  args[0] == "test_x": test_x(); return` per test, each carrying the
  span of the test's own declaration so a trap reports the entry frame
  at the line the test is written on. The entry also checks the command
  line it was handed, so a person who runs the artifact by hand with no
  name, or a name that matches nothing, gets a clear message rather than
  an index trap.
- **One call per test.** The CLI calls the artifact once per test: one
  `dlopen` per file, one `luce_main` per test, and each call a fresh
  `Runtime` — so per-test heap, scopes, depth budget, leak census and
  trap report all fall out of machinery that already exists. A trap
  fails *that call*; the loop is in `luce test`, so every failure in the
  file is still reported. Luce has no undefined behaviour to escape a
  runtime, and call depth is policy rather than a native-stack limit, so
  process-per-test would buy nothing.
- **The host is the real host** (`src/apps/host.zig`), given to the
  `luce` binary for this command the way loom wields it — including the
  screen-restore-before-report duty, so a full-screen test that traps
  does not leave the terminal raw, and the worker slots, so a test may
  itself `spawn`.
- **The artifact is a scratch file.** It is written beside the source
  under a name distinct per writer (`NAME.luc.<pid>-<tid>.test.lc`),
  claimed exclusively before it is built, and removed when the file's
  tests are done. It is never `NAME.lc` — that is the name `luce build`
  writes, and a test runner must not be able to delete a built artifact
  — and never the project's `.luce/cache/`, which is loom's warm-run
  path. `luce test` leaves a directory exactly as it found it.
- Tests run in declaration order within a file, files in sorted order.

## The report, and what fails a test

The whole report goes to standard output — trap renderings and compile
diagnostics included — because it is one document a person reads top to
bottom. A test's own `print` lands on the same stream, in order,
bracketed by the per-call loop; its `print_error` is its own and still
goes to standard error. Output is the shell palette's when writing to a
terminal, plain otherwise.

Per file, per test: the name, `ok` or `FAIL`, and on failure the
rendering indented under the name. A test fails by:

- **trap** — rendered as every trap is: code, message,
  `file:line:column`, and call trace;
- **raise** — a `-> !` test's error, rendered with its message and
  origin;
- **leak** — a nonzero per-run census, because a leaking test is a
  failing program even when its asserts held (this is a guard against an
  engine bug: ARC frees everything, so no Luce source can reach it);
- **`exit`** — a test that calls `exit` fails whatever status it chose,
  because a test's job is to return and an early exit is the one way
  generated code could skip the census.

A file that fails to *compile*, or a discovery refusal, is reported and
makes the run red, and the remaining files still run. One summary line —
`7 passed, 1 failed, 8 tests in 3 files` — closes it, and the exit
status is 0 when everything passed and 1 for anything else, so a build
script needs no parsing.

## Deliberately absent

- **No assertion library** — `assert(x == y)` with the language's own
  diagnostics. If bare messages prove thin, the fix is the compiler
  rendering the failing comparison's operands, not a matcher DSL.
- **No setup/teardown, no fixtures** — a helper called first thing is a
  fixture, and ARC already guarantees cleanup.
- **No filtering, tags, or skips** — run a file.
- **No mocking** — the host table is the seam; a scripted host is the
  honest version and waits for a customer.

Parallel test *files* and a per-call scripted host are the two
extensions this architecture was chosen to allow; neither is built yet.

---

## The repository's own release gate

The tests that prove Luce itself have a second layer below `luce test`.
Ownership is by the claim a test makes, not by incidental dependencies
in its fixture: a test that calls `std.lists.sort_by` to exercise a
callback is still a language test, while a test of `sort_by`'s ordering
and stability is a standard-library test. That distinction keeps the
core language, standard library, host, products, and tools
independently diagnosable.

```text
zig build test
```

is the one deterministic release gate. It runs these owner lanes:

| lane | owns |
|---|---|
| `test-luce` | Unit and structural tests beside the lexer, parser, semantic passes, MIR, optimizer, interpreter, and shared runtime. |
| `test-specs` | Every observable language contract, on the interpreter and compiled engine, compared by the differential harness. |
| `test-apps` | The `luce` and `loom` implementation and their command-line product tests. |
| `test-packages` | Userland packages through the shipped `luce test` command. |
| `test-editor-product` | The editor model's own Luce tests and the standalone editor build. |
| `test-example-builds` | Every bundled example compiled through the shipped compiler path. |
| `test-benchmarks` | Every benchmark compiled, but never timed as part of correctness testing. |
| `test-tools` | Documentation and site guards, grammar generation, test-suite ownership, and the VS Code extension's JavaScript tests. |

`test-specs` is one fused binary on purpose: splitting it physically
would compile and load the LLVM-backed harness repeatedly and let
several memory-heavy copies compete. Its tests still have exactly one
logical owner, enforced by `tools/test_suites.zig` and its directory
audit:

| focused lane | specification owner |
|---|---|
| `test-language` | Core syntax, types, control flow, functions, memory management, modules, threading semantics, diagnostics, optimization equivalence, module round trips, and the synthesized Luce-test entry. |
| `test-stdlib` | `std`, including math, lists, strings, paths, files, OS, JSON, and ZIP. |
| `test-host` | The raw host boundary and its byte/resource representation. |
| `test-backend` | Source-to-loaded-machine-code LLVM behavior and defensive lowering checks. |
| `test-editor` | The editor's scripted differential behavior plus `test-editor-product`. |
| `test-examples` | The adventure's scripted differential behavior plus every bundled example build. |
| `test-spec-harness` | The comparison harness and scripted host used by all specification owners. |

The focused specification lanes are developer-feedback commands; the
release gate uses the fused run, so no specification is executed twice.
A new `src/luce/specs/*_spec.zig` file without exactly one suite fails
`test-tools`, and the full runner refuses an unclassified or overlapping
test name before executing the corpus. The fused roster is ordered by
those same owners — language, standard library, host, backend, editor,
then examples — so its progress reads as a sequence of phases. Harness
guards bracket the run because every phase imports the shared
comparator, and the two memory-heavy release-gate binaries are
serialized to keep their memory use predictable.

Feature work has narrower feedback lanes. They select tests from the same
owned binaries; they do not create alternate suites or change the release
gate:

| command | proves |
|---|---|
| `zig build test-interfaces` | Interface declarations and refusals, conformance matching, witness layout, heterogeneous dispatch, ARC ownership, and cross-module use. |
| `zig build test-classes` | Class identity, initialization, mutation, weak edges, deinitialization, runtime hardening, and interface use. |
| `zig build test-weak-references` | Zeroing storage, upgrades, row reuse, copies, and supported ARC object families. |
| `zig build test-closures` | Capture ownership, weak captures, bound receivers, cycles, and diagnostics. |
| `zig build test-exceptional-ownership` | Releases across errors, traps, `catch`, loop exits, returns, and workers. |
| `zig build test-optimizer` | Reachability and dead-code rewrites preserve ownership and implicit lifecycle edges. |

These lanes are organized by semantic risk rather than by a target test count.
One differential specification runs on both engines and compares the leak
census; a structural test pins an exact MIR invariant; a runtime test attacks
allocation, malformed values, or graph depth directly. Counting all three as
interchangeable “tests” would hide what is actually proved.

### Where a test belongs

- A test of observable Luce behavior belongs in `src/luce/specs/` and
  runs on both engines. Compiler refusals live there too; a rejected
  program has no engine run to compare.
- Standard-library behavior lives in `std_spec.zig`, `json_spec.zig`, or
  `zip_spec.zig`. A language test that merely *uses* a std function to
  construct the feature under test stays with that feature.
- The editor has three deliberate layers: scripted behavior on both
  engines, pure model/keymap tests through `luce test`, and a standalone
  executable build. None is part of the core-language lane.
- Product, package, example, benchmark, site, documentation, grammar,
  and extension tests have their own lanes. They remain in the release
  gate but cannot inflate or obscure the core-language result.
- A beside-the-code test may drive a program only to inspect an internal
  structure the program cannot observe — the interpreter's reusable
  frame storage, for example. Damaged serialized MIR is likewise a
  decoder/verifier input, not a Luce program. These are narrow,
  documented structural seams, not alternate semantic suites.

### Hardening and fuzzing

Compiler-stage property targets are named `fuzz:` so the build can run
them as a coherent hardening lane:

```text
zig build test-hardening
```

runs the property corpus and the fixed-seed near-miss parser stress
test — the quick feedback loop for changes at the source, front-end,
verifier, or module boundaries.

```text
zig build test-fuzz --fuzz=10000
```

lets Zig's coverage-guided fuzzer explore the same `fuzz:` targets from
their checked-in seeds. A generated failure is a reproducible input to
minimize, promote into the corpus, and pin with a normal regression
test; the corpus is not a substitute for semantic examples or
differential specs.
