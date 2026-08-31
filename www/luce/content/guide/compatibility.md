# Version Compatibility

Luce is currently pre-1.0. A 0.x release is a coherent compiler, runtime,
standard library, TermUI package, editor, extension, and documentation set;
it is not a promise that source or binary artifacts from an older 0.x release
will continue to work unchanged.

This freedom is deliberate. The language is still being simplified from real
application experience, and carrying migration layers for an unreleased
surface would make both the compiler and its documentation harder to trust.

## Use one release as one toolchain

The versioned installer replaces the current installation under
`~/.local/luce` with a complete release:

```sh
curl -fsSL https://luce.luciaos.com/install/0.30/install.sh | bash
```

Running it again downloads and verifies a fresh archive before replacing the
installed tree. The compiler, startup/runtime libraries, editor, TermUI
package, and VS Code extension therefore move together. Keep those pieces from
one release rather than combining a new compiler with copied libraries from an
older archive.

The installer publishes one coherent release for macOS 15 or newer on Apple
Silicon and for glibc Linux 2.28+ on x86-64 or ARM64. It chooses the archive
itself and refuses an older operating system before changing an installation.
The Linux compiler contains its pinned LLVM and does not depend on a
distribution LLVM package; it does require the host's `cc` driver to finish
native links. Linux with musl, macOS on Intel, and Windows do not yet have the
same release contract.

## Source compatibility before 1.0

Before 1.0, a release may rename a type, change syntax, remove an experiment,
or tighten a rule without a compatibility mode. The current documentation is
the source contract for the current toolchain. There is no migration test
suite because there is no released historical source language to preserve.

When updating:

1. install the new release as one unit;
2. rebuild from `.luc` source;
3. follow diagnostics rather than copying old native artifacts forward; and
4. consult [Status](/status/) and the current Guide for changed boundaries.

Once 1.0 is intentionally declared, source compatibility becomes a product
policy and will be documented with the releases it covers. It should not be
inferred retroactively from current 0.x version numbers.

## Native artifacts

The default result of `luce build` is a target-native executable. A `.lc`
library is also native machine code. Neither is portable across CPU/OS targets,
and `.lc` records enough identity for `loom` to refuse an incompatible file.
Treat a `.lc` exactly like an executable: run one only when you trust who built
it. Its format checks prevent accidental incompatibility; they are not a
sandbox for hostile machine code.

The compiler’s internal `.lcm` form is verified serialized MIR, used as a seam
and cache input rather than a distribution format. Its current format version
is 56. Changes to serialized instructions, types, or layouts bump that number;
old modules are refused and rebuilt from source.

Native programs and libraries call the published host table. Its current ABI
version is 24. A host-table layout change bumps the ABI, and a library carrying
another version is refused instead of being called optimistically.

These refusals are safety features. An artifact that looks plausible but was
built for another memory or host contract is more dangerous than a clean
rebuild.

## Packages

A `luce.yaml` manifest asks for exact package versions. The resolver does not
interpret ranges, choose the newest copy, or silently prefer one package shelf
over another. A hash may pin the package bytes as well as its version.

The release ships TermUI in its installed `LUCE_LIB` shelf. Projects under
active development may point at a direct source folder. There is currently no
network registry or package fetch/update service, and `luce package publish`
refuses after validating the local package because no honest upload target has
been configured.

Package source is compiled with the consuming toolchain. Until 1.0, a package
author should state which Luce release was used and expect to update source as
the language changes.

## Documentation compatibility

Every runnable sample, expected error, expected trap, link, anchor, and selected
public API roster on this site is checked by the toolchain used to build the
site. That keeps the current documentation synchronized; it does not preserve
old pages as compatibility references.

The [Language Reference](/guide/reference/) states exact current rules.
[Command-Line Tools](/tools/command-line/) explains the artifact forms and
version commands. [Status](/status/) separates implemented behavior from the
remaining design work.

Continue with [The Basics](/guide/basics/).
