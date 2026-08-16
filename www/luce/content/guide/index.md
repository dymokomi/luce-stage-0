# The Luce guide

This is one book for learning Luce and looking it up later. The distinction
between explanation and specification is useful, but it does not need two
top-level destinations.

## How the book is organized

**Language Guide** chapters teach the language in reading order. They start
with a complete program, establish values and operators, then build toward
data modeling, failure, concurrency, ARC, access control, and modules.
Each chapter assumes only the ideas that appeared before it.

**Tools and Projects** covers the work around source code: building,
editing, packages, tests, complete programs, and performance. Read these
chapters when the corresponding task first becomes real.

**Language Reference** closes the book with exhaustive lookup material.
Those chapters define grammar, types, expressions, declarations, memory,
diagnostics, modules, and built-ins. They favor precision over narrative.

## How to read it

If Luce is new, read the [Tour](/tour/) once, then begin with
[The Basics](/guide/basics/) and follow the Next links through the Language
Guide. You do not need to memorize a reference table before writing useful
code.

If you already know the language, use search or jump directly to a chapter.
When a teaching chapter summarizes a rule, it links to the exact section in
the Language Reference. Library APIs remain in the separate
[Library](/library/) because they describe imported modules and packages,
not the language itself.
