# Command-Line Tools

This section covers the work around Luce source: installing a release,
building artifacts, editing, organizing projects and packages, running tests,
reading complete programs, and measuring performance.

The language book stays focused on semantics. Come here when the question is
“what command should I run?” or “how should this project be arranged?” rather
than “what does this expression mean?”

## Toolchain

Start with [The `luce` and `loom` Commands](/tools/command-line/) for
installation, builds, checks, native executables, `.lc` libraries, debug and
release modes, and the intentionally smaller role of `loom`.

[Editor Support](/tools/editor/) covers the standalone Luce editor and the
syntax extension installed for VS Code, VS Code Insiders, and Cursor. Both use
the same installed compiler; there is no second language implementation.

## Projects

[Packages and Projects](/tools/packages/) begins with a `main.luc` and a direct
source subfolder, then adds `luce.yaml`, exact versions, local authoring
commands, installed package shelves, and the current no-registry boundary.

[Testing](/tools/testing/) explains discovery, ordinary `test_` functions,
progress and failure output, and how a project’s tests are kept separate from
the compiler repository’s own release gate.

[Complete Programs](/tools/programs/) points to the checked examples—from a
sort and word counter to ZIP, an adventure, TermUI, and the editor—so language
features can be read in the context of a whole program.

[Performance](/tools/performance/) explains how to measure release artifacts
and which representation choices materially affect text and numeric work.

Imported APIs are documented separately in the [Library](/library/). Current
platform and unfinished product boundaries are listed on [Status](/status/).
