# Resolved bugs

This is the compact historical counterpart to [MISSING.md](MISSING.md). An
entry records the incorrect behavior, the user-visible repair, and the proof
that closed it. Current contracts remain in the living reference; this file
does not duplicate them.

## 2026-08-16 — `luce` omitted `test` from its usage

No-argument help omitted the implemented `luce test [PATH ...]` command and
joined two unrelated `--emit` clauses into a malformed sentence. Help now
lists the complete top-level command roster and explains that `exe` is the
default output form. The compiler product test pins every command and the
corrected prose.

## 2026-08-16 — `luce test` named a test only after it finished

The runner flushed a file heading before execution but did not identify the
individual test until its final verdict. A slow or hung test therefore looked
anonymous. Every call now emits and flushes a plain `test` progress line before
entry, then emits a separate `ok` or `FAIL` verdict. Product tests pin progress,
program output, and verdict order; redirected and terminal reports use the same
stable text layout.

## 2026-08-16 — ordinary projects hit small fixed ceilings

The compiler refused an otherwise valid import graph after 64 modules, and
the `loom` shell refused a program invocation after 16 arguments. Neither
number followed from the language, artifact format, or host ABI. Import
loading now grows until its allocator reports exhaustion, with a regression
that retains 128 imported modules. Shell tokenization grows with the input and
has a 128-argument regression. Structural recursion and hostile-input limits
remain where they protect the compiler rather than ration ordinary programs.
