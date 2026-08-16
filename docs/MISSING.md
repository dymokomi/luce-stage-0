# Known bugs

This file tracks confirmed incorrect behavior in the current tree. A report
belongs here only when an existing contract, documented behavior, or supported
workflow is reproducibly wrong.

Feature requests, unratified design questions, broad coverage campaigns,
refactors, optimizations, and deliberate non-goals are not bugs and do not
belong in this file. Their owning references, plans, or records retain that
context.

Resolved bugs are removed from this file once the fix and its proof land.

## `luce` omits `test` from its usage

Running `luce` with no arguments prints the accepted commands, but the output
does not include the implemented `luce test [PATH ...]` command. The following
paragraph is also malformed: `--emit says which shape to write; the default is
exe differs between them`.

The command is implemented and documented elsewhere, so the compiler's own
help is an incomplete and confusing description of its interface. The product
test for no-argument usage currently checks only the heading and one build
form; it does not pin the complete command roster or the prose around
`--emit`.

Expected: no-argument usage lists every accepted top-level command, includes
`luce test [PATH ...]`, and explains the default executable form in a complete
sentence. A product test must pin that roster.

## `luce test` does not identify a test until it finishes

The runner prints a source-file heading, compiles the file, and flushes before
calling each test. It prints the test name only in the later `ok` or `FAIL`
line, after the call returns. A slow or hung test therefore leaves the user
with no way to tell which test is active.

Expected: announce and flush the individual test name before entering it while
preserving deterministic, readable terminal output and stable redirected
output. Product tests must prove both the pre-call progress line and the final
verdict ordering.
