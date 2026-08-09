# A dirty tree, on purpose

`tools/spelling.zig` refuses any Luce source in this repository that
still spells a builtin type the retired TitleCase way.  A guard that
only ever runs against a clean tree proves nothing: narrow its scope
table to nothing and every test still passes, which is exactly what a
mutation sweep found.

So this directory is a miniature repository laid out with the same
shape the guard scans — `examples/`, `bench/`, `src/luce/std/`,
`www/luce/content/`, `src/luce/specs/` — with one violation in each, of
the kind that scope is meant to catch.  The guard's tests point it
here and require it to find every one.

**Nothing here is compiled or run.** These are fixtures for a text
scan, and the file extensions are what make them fixtures for the
right scope. The guard skips this directory in earnest, because
`tools/` is not one of the trees it walks.
