# The Luce reference

This is the normative description of Luce: what the compiler in this
repository accepts and what it means. It is terse on purpose.

**What it is not.** It is not an introduction — that is
[the tour](/tour/). It is not a collection of worked programs — those
are [the examples](/examples/). It is not a rationale; where a
decision has reasons worth reading, [the guides](/guide/) hold them
and this document links out.

**Where it disagrees with the compiler, the compiler is right.** These
pages are written against the tree, and every sample on them is
compiled and run when the site is built, but the source and the tests
in the repository are the last word.

## Citing a rule

The [ownership](ownership/) page gives every one of the 45 ratified
situations a fixed anchor — `#s21`, `#s13` — that does not move when
its wording does. The compiler quotes those numbers in its
diagnostics, so a message that says `[OWNERSHIP.md S21]` points at
exactly one clause here.
