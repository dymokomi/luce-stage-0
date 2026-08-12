# Testing

Luce has no test framework, and `luce test` is not one. A test is an
ordinary function in an ordinary `.luc` file, it asserts with the
`assert` the language already has, and it passes by returning. The
compiler discovers it by name and the runner calls it.

That is the whole idea, and it is Zig's: no registration, no fixtures,
no matchers, no `@Test`. What `luce test` adds to the language is
discovery, a synthesized entry, and a report — and no new semantic.

## A test is a public `func test_*()` taking nothing

Put tests in a `tests/` directory beside your code. Every top-level
function whose name begins `test_` is a test; everything else in the
file is a helper.

```luce module file=tests/geo_test.luc
func square(side: long) -> long:
    return side * side

func test_square_of_three():
    assert(square(3) == 9)

func test_square_of_zero():
    assert(square(0) == 0)
```

```console
$ luce test
tests/geo_test.luc
  ok    test_square_of_three
  ok    test_square_of_zero

2 passed, 0 failed, 2 tests in 1 file
```

Bare `luce test` means the `tests/` directory under wherever you typed
it, exactly as `luce build FILE` resolves `FILE`. You can name files
and directories instead, and a directory is walked recursively in
sorted order, so the report is a property of your tree and not of the
filesystem's mood.

The exit status is `0` when everything passed and `1` for anything
else — a failing test, a file that could not be compiled, a `test_*`
that could never have run. A build script needs no parsing.

## How a test fails

Four ways, and every one of them is something the language already
had to say.

A **trap** is a bug, and it is reported the way every trap is: the
stable code, the message, `file:line:column`, and the call trace. An
**error** is news the test did not handle, and is reported the way
every uncaught error is: the message and the one place it was raised
(see [Traps are bugs, errors are news](/guide/failure/)).

```luce module file=tests/stack_test.luc
func top(xs: list(long)) -> long:
    return xs[len(xs) - 1]

func test_top_of_a_stack():
    var xs: list(long) = [1, 2, 3]
    assert(top(xs) == 3)

func test_top_of_an_empty_stack():
    var xs: list(long) = new list(long)
    assert(top(xs) == 0)

func test_reads_a_missing_file() -> !:
    let text = try file_read("nowhere.txt")
    assert(len(text) == 0)
```

```console
$ luce test
tests/stack_test.luc
  ok    test_top_of_a_stack
  FAIL  test_top_of_an_empty_stack
        luce: trap: index out of bounds [index_bounds]
            at top (tests/stack_test.luc:2:5)
            at test_top_of_an_empty_stack (tests/stack_test.luc:10:5)
            at main (tests/stack_test.luc:8:6)
  FAIL  test_reads_a_missing_file
        luce: error: cannot read nowhere.txt [io_failed]
            raised in test_reads_a_missing_file (tests/stack_test.luc:13:5)

1 passed, 2 failed, 3 tests in 1 file
```

A test that wants to say "this call should fail" writes `-> !` and
either propagates with `try` or handles with `catch`; ignoring a
fallible call is a compile error, so a test cannot silently drop the
failure it was written to check.

The other two ways are shorter. A test that **leaks** fails even when
its asserts held, because a leaking program is a failing program. A
test that calls **`exit`** fails by name whatever status it chose: a
test's job is to return.

## What `luce test` refuses

A test that cannot run is a mistake, not an absence. `luce test`
refuses it by name rather than skipping it quietly, and the message
names the fix.

```luce module file=tests/rules_test.luc
private func test_never_runs():
    assert(true)

func test_doubling():
    assert(21 * 2 == 42)
```

```console
$ luce test
tests/rules_test.luc
  tests/rules_test.luc:1:14: test_never_runs is private and would never run; drop private, or rename it if it is a helper

0 passed, 0 failed, 0 tests in 0 files, 1 file not run
```

The same goes for a `test_*` that takes parameters, one that answers a
value other than nothing or `!`, and one written inside a `struct`, an
`enum` or a `union` — none of them can be reached by name, so none of
them is quietly left out.

Silence is treated the same way, with one exception. A file you
*named* on the command line has to hold tests; so does a swept file
called `*_test.luc`, which claimed the name. Any other swept file with
no tests is a helper module, is skipped, and is counted in the summary
— `1 file without tests` — so a file that has gone quiet is one glance
away rather than invisible.

## What a test file may do

Everything an ordinary module may do, because it is one. It imports
the code under test the ordinary way, obeys the host gate, and may
define helpers and a `main` — `luce test` ignores the `main`.

Under a `luce.yaml` its imports anchor at the project root, so
`tests/geo_test.luc` writing `import geo` reaches the project's
`geo.luc` rather than a phantom `tests/geo.luc`. Without one they
resolve beside the test file, and a compile that fails is told so.

## How it runs

Each file is compiled **once**. The compiler synthesizes the entry for
it — `func main(args: list(string)) -> !`, the fourth of the four entry
shapes — whose body reads a test name out of `args` and calls that one
test directly. Then the runner opens the artifact once and calls it
**once per test**, handing it one name each time.

That is the whole isolation mechanism, and it is machinery that
already existed: every call to a compiled artifact gets a fresh
runtime, so each test has its own heap, its own scopes, its own call
depth budget, its own leak census and its own trap report. A trap ends
that call and nothing else, because the loop is in `luce test` and not
in the program. Tests run in declaration order, files in sorted order,
and nothing runs in parallel.

`luce test` takes no build options and always builds debug: the report
is made of trap locations, and `--release` strips them.

## What it deliberately does not have

- **No assertion library.** `assert(x == y)` with the language's own
  diagnostics. If bare messages prove thin, the fix is the compiler
  rendering the failing comparison's operands — it has the spans — not
  a matcher DSL.
- **No setup or teardown, no fixtures.** A helper called first thing
  is a fixture, and scope ownership already guarantees cleanup.
- **No filtering, tags or skips.** Run a file.
- **No mocking.** The host table is the seam; a scripted host is the
  honest version of that idea and is waiting for a customer.
