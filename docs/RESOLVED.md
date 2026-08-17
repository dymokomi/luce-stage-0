# Resolved bugs

This is the compact historical counterpart to [MISSING.md](MISSING.md). An
entry records the incorrect behavior, the user-visible repair, and the proof
that closed it. Current contracts remain in the living reference; this file
does not duplicate them.

## 2026-08-17 — the documentation verifier fed executables to `loom`

`luce build` correctly defaults to an executable, but the site verifier still
relied on its former library default before asking `loom` to run each sample.
Every runnable documentation example was consequently compiled and then
rejected as the wrong artifact kind. The verifier now requests
`--emit=library` explicitly; a complete site build compiles and runs the full
published sample corpus with the freshly built `luce` and `loom` pair.

## 2026-08-17 — standard-library implementation names polluted every program

The compiler exposed each host operation as a global builtin and reserved its
name everywhere. A program therefore could not declare ordinary functions
such as `clock_ms`, `dir_create`, or even several names also used by receiver
methods, including `append` and `has`. Embedded standard-library source now
uses a compiler-only `Builtin.NAME` bridge selected by source provenance;
projects and packages reach host services only through `std.files`, `std.os`,
`std.ui`, and `std.gpu`. The public prelude, syntax highlighters, and reference
now contain only public names. Structural tests hold every internal intrinsic
out of the reserved roster, while dual-engine language tests prove the old
names and a user-defined `Builtin` namespace remain ordinary identifiers.

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

## 2026-08-16 — released macOS tools disagreed on their minimum system

An unversioned cross-target build produced `luce` and `loom` with a macOS 13
load command while the editor required macOS 15. The release now targets
`aarch64-macos.15.0` explicitly, audits every shipped tool's Mach-O minimum,
and refuses macOS 14 or older before downloading. A ReleaseSafe archive-shaped
build proves `luce`, `loom`, the editor, and generated Luce artifacts all carry
the 15.0 deployment target.
