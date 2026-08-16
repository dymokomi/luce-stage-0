# tools

Developer tooling that ships with the repo but isn't part of loom.

- `doccheck.zig` — compiles every Luce sample in the catalogued current
  references, plans, and decision records, while keeping historical fences in
  decision records only.
- `spelling.zig` — a rename guard: retired spellings are held out of current
  reference prose and executable Luce source by name.
- `grammar.zig` — generates `vscode-luce/`'s grammar from the
  compiler's own word and symbol tables rather than from a copy of
  them, and refuses to write one that is short a word.
- `test_suites.zig` + `test_suites_test.zig` — assign every executable
  specification test to exactly one owner and fail when a new spec file is
  missing from, or overlaps, that catalogue.
- `test_runner.zig` — the bounded progress and 15-second heartbeat used by
  the long internal and differential test binaries.
- `sweep.sh` — the mutation harness: breaks the compiler on purpose and
  checks the suite notices.
- `linux-check/` — the container the tree is built and tested in on
  Linux, because it is developed on macOS and "portable by
  construction" is a claim until something runs it.
- `testdata/` — inputs the guards above read.
- `vscode-luce/` — generated syntax highlighting and brace-aware indentation
  for `.luc`.

Every guard here is a step of `zig build test`, so none of them is a
command anyone has to remember; `sweep.sh` is the one exception and is
run by hand.

Everything that used to be here tested the hand-written code generators
and went away with them.
