# The standard library

Eight modules, written in ordinary Luce and **embedded in the
compiler** — the way Zig ships `lib/std` with its compiler, minus the
install path. Wherever the compiler runs, `import std.math` just
works. There is no package manager, no search path and nothing to
install.

Because they are ordinary modules, standard code obeys every language
rule: the ownership model, the checked arithmetic, and the host gate.
`import std.files` inside a program compiled without host access is a
compile error, because file access genuinely does not exist there.

Naming follows the language's own style. Modules are short lower-case
nouns and functions are short verbs read *with* the module prefix —
`files.read(path)`, `math.round(x)` — so bare names stay short without
colliding.

## Two constraints, deliberate for now

**No mutable module state.** File-scope `const` holds a folded value or
an immutable program-root table, never a mutable global. Where state is
genuinely needed the idiom is to hand it to the caller:
`strings.split(s, ",")` returns a `list(string)` the caller owns, and
mutation through a borrow is ordinary Luce.

**Absence and failure are told apart.** A function that may find
nothing answers `T?`; one that may *fail* says `!`. `files` is written
that way throughout, and `math`'s five whole-array reductions answer
`double?` because an empty array has no mean.

## Adding a module

The repository's rule is four steps: write `src/luce/std/NAME.luc` as
ordinary Luce, add one row to the table that embeds it, prove it in
the spec suite, and document it.
