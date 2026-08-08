# Repository Guidelines

**[`CLAUDE.md`](CLAUDE.md) is the single source for how this
repository works** — its architecture, its conventions, and what a
change to any part of it costs.  Read it.  This file existed as a
second, overlapping description of the same tree, and two descriptions
of one thing drift: they had already disagreed about which directories
`zig fmt` covers, and this one was still offering a deleted subsystem
as the model commit subject.  So it is a pointer now, and there is
nothing here to fall out of step.

What to read, in order:

- [`CLAUDE.md`](CLAUDE.md) — the architecture, the stages, the seams,
  and the rules that are load-bearing.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — build, test, where a test
  goes, style, and the commit convention, in short form.
- [`docs/CODING_GUIDE.md`](docs/CODING_GUIDE.md) — how Zig is written
  here.  Authoritative and intentionally opinionated.
- [`docs/README.md`](docs/README.md) — the index of the documents, and
  which of them are frozen decision records.

Three things worth having in front of you before the first edit,
because each one silently costs you something if you miss it:

1. **Where a test goes.** Anything that runs a Luce program is a
   specification and lives in `src/luce/specs/`, where it runs on both
   the compiled path and the differential oracle and the two are
   compared.  Anything that inspects a structure lives beside the code
   it proves.  A new language package must be added to
   `src/luce/luce.zig`'s re-exports *and* its test block, and a new
   spec file to `src/luce/specs.zig`'s, or the tests do not run.
2. **`zig fmt src/ build.zig www/luce/src/ tools/`** before committing.
   The documentation site's generator and repository tools are Zig too.
3. **Semantics live in `src/luce/runtime/` and nowhere else.**  The
   compiled path and the oracle both call it, so a rule implemented on
   one side only is a bug by construction.  Host access goes through
   the published table (`src/luce/08_llvm/abi.zig`, or
   `interpreter.Host` on the oracle's side) or an explicit `std.Io`;
   `src/luce/` never touches the host directly.  A change to the
   instruction set, the intrinsics or the trap codes bumps
   `module.format_version`; a change to the host table bumps
   `abi.version`.
