# Contributing

Short, because most of it is pointers.  The rules that matter are
written down elsewhere and this file says where.

## Build

Zig 0.16, pinned in `build.zig.zon`.  **LLVM is a build prerequisite of
the `luce` compiler** — the code generator calls libLLVM in process —
and `cc` is a prerequisite of building at all, because compiling a
bundled program is a link.  `loom` links no LLVM, so a machine that
only *runs* Luce programs needs none.

```sh
./build.sh   # installs build/luce, build/loom, build/editor,
             # build/lib/*, and build/examples/<name>/<name>.lc
```

`VERSION` is the one shared two-component release label during the 0.x
series; both binaries expose it with `--version`. It is separate from the
module format and host ABI versions.

`./install.sh` is for a user-local daily-use snapshot on macOS or Linux. It
builds ReleaseSafe by default, copies both binaries and both static libraries
under `~/.local`, and adds `~/.local/bin` to the user shell profile without
using `sudo`. `--no-build`, `--no-path`, and `--prefix DIR` are available for
existing builds, profile-free installs, and another user-owned prefix. Keep
tests and benchmarks on their explicit `build/` paths; an installed snapshot
must not silently become the thing they exercise.

`build.zig` finds LLVM by asking `llvm-config`, on `PATH` or in the
usual Homebrew and distribution prefixes; `-Dllvm-config=PATH` points
it somewhere else.  When the system LLVM is the wrong one,
[`./vendor-llvm.sh`](vendor-llvm.sh) builds a pinned one from source
and `./build.sh` picks it up automatically.  That is the supported
answer, not a workaround.

## Test

```sh
zig build test
```

The build summary prints the count; no document repeats it, because
every document that ever did went stale.  It runs the executable
specification, the language, compiler and terminal suites, and the
documentation site's generator — and it compiles and links every
bundled program and every benchmark, which is why `cc` and an
installed `libluce_rt.a` are prerequisites of testing too.

It does **not** refresh `build/`.  Run `./build.sh` for that.

The focused hardening lanes are useful while changing a front-end seam:

```sh
zig build test-hardening          # deterministic fuzz corpus + near misses
zig build test-fuzz --fuzz=10000  # coverage-guided iterations from that corpus
```

Fuzz failures should be reduced to a small checked-in corpus entry and an
ordinary regression test before the change is committed.

## Where a test goes

One rule decides it:

> **Anything that runs a Luce program is a specification and lives in
> `src/luce/specs/`**, where it runs on both the compiled path and the
> differential oracle and the two are compared — prints, trap code,
> trap message, call trace frame for frame, leak census, and the world
> each left behind.  **Anything that inspects a structure lives beside
> the code it proves**, as a `test` block in the same file.

Two registration steps silently skip your tests if you miss them: a
new language package must be added to `src/luce/luce.zig`'s re-exports
*and* its test block, and a new spec file to `src/luce/specs.zig`'s.

Tests are named after what they prove — `test "truncated, oversold,
and damaged modules are rejected"` — use `std.testing` directly with
no framework, and run leak-checked under `std.testing.allocator`.
Cover success, bounds failure, and round-trip or rejection where
relevant.

## Style

[docs/CODING_GUIDE.md](docs/CODING_GUIDE.md) is authoritative and
intentionally opinionated.  Read it before the first pull.  The short
version: plain old-school code over clever ceremony, errors as values
with small explicit error sets, explicit allocation with a `deinit` on
everything that holds heap, doc comments that say who owns what, and
file splits only where a subproblem has a one-to-three-function
interface — never because a file got long.

```sh
zig fmt src/ build.zig www/luce/src/ tools/
```

Run it before every commit.

## Documentation

[docs/README.md](docs/README.md) indexes the documents and
says which are current and which are frozen decision records.

User-facing prose lives on the site, **[luce.luciaos.com](https://luce.luciaos.com)**,
built from [`www/luce/`](www/luce/) — see [www/luce/README.md](www/luce/README.md).
**Every Luce sample on it is checked by the freshly built toolchain.**
Runnable samples execute and their output is compared byte for byte;
expected traps, raises and refusals are checked as such.  A broken
sample, mismatched claimed result, dead link or dead anchor fails the
build, and a fenced `luce` block that does not say what becomes of it
is a build error.  The surrounding prose remains human-reviewed.

The site also holds the compiler's lists to its own reference pages
(`www/luce/src/coverage.zig`): a builtin, method, trap code, std function
or command-line option the compiler has and the reference does not is
a failed build.  If you add one, the test will tell you which page
wants it.

### Luce in `docs/` is compiled too

`tools/doccheck.zig` runs in `zig build test` and compiles **every**
fenced `luce` block in every document.  The site *runs* its samples
and compares their output; a document's snippets only have to be real,
so a fence says which of four things it is:

| Fence | What it means |
|---|---|
| ```` ```luce ```` | A whole file — declarations, and `func main()` if it wants one.  Must compile. |
| ```` ```luce fragment ```` | Statements from inside a function body.  Dedented, indented into a `func main():`, and compiled. |
| ```` ```luce refused ```` | A program the compiler must **reject**.  Showing a mistake is a claim about the compiler and goes stale the same way working code does.  Combines with `fragment`. |
| ```` ```luce historical ```` | Code a **decision record** shows as an illustration: an older spelling, a refused syntax, a fragment from a program nobody wrote.  Never compiled. |

Anything that is not Luce — an API index, a syntax sketch with `…` in
it — is a ```` ```text ```` fence and no business of the checker's.

`historical` is the only exemption there is, and it belongs to
decision records alone: `grep -rn 'luce historical' docs/` lists every
use of it in one line each, and the living documents carry none.
`tools/documents.zig` is the one catalogue both `doccheck.zig` and
`tools/spelling.zig` read, and a test pins it to `docs/README.md`'s two
tables. The spelling guard refuses a retired TitleCase type name in a
living document's *prose* as well as its code, because a sentence in a
reference page is as normative as a sample in one.

## Committing

Single-developer repository: changes go directly to `main`, no feature
branches and no pull requests, unless the maintainer asks otherwise.

Subjects are concise and descriptive, often scope-led
(`Benchmarks: ...`), not Conventional Commit prefixes.  Explain
motivation, verification and — for anything touching performance —
benchmark evidence in the body.  `bench/compare.sh GIT-REF` is the
authoritative regression check, because it interleaves two builds on
the machine in front of you.

Do not commit `build/`, `zig-out/` or `.zig-cache/`.

## License

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in this project shall be dual licensed under
the MIT license and the Apache License (Version 2.0), without any
additional terms or conditions, as in Rust.
