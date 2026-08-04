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
./build.sh   # installs build/luce, build/loom, build/lib/libluce_rt.a,
             # build/programs/*.lc
```

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
zig fmt src/ build.zig site/src/
```

Run it before every commit.

## Documentation

[docs/README.md](docs/README.md) indexes the thirteen documents and
says which are current and which are frozen decision records.

User-facing prose lives on the site, **[luce.luciaos.com](https://luce.luciaos.com)**,
built from [`site/`](site/) — see [site/README.md](site/README.md).
**Every Luce sample on it is compiled and run by the freshly built
toolchain**, and the output printed under a sample is the output that
run produced.  A wrong claim, a dead link or a dead anchor fails the
build, and a fenced `luce` block that does not say what becomes of it
is a build error.  There is no unverified code on the site by
construction.

The site also holds the compiler's lists to its own reference pages
(`site/src/coverage.zig`): a builtin, method, trap code, std function
or command-line option the compiler has and the reference does not is
a failed build.  If you add one, the test will tell you which page
wants it.

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

**To be chosen.**  There is no `LICENSE` file in this repository yet,
and picking one is the owner's decision alone.  Until it is made, the
code is under exclusive copyright by default — assume you may read it
and not that you may redistribute it.

## License

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in this project shall be dual licensed under
the MIT license and the Apache License (Version 2.0), without any
additional terms or conditions, as in Rust.
