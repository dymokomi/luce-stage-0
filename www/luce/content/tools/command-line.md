# The luce and loom Commands

The first Luce workflow is deliberately ordinary: write a source file,
compile a native executable, and run that executable.

- `luce build FILE` creates a program your operating system can launch
  directly. The executable takes the source name, without `.luc`.
- `editor FILE` gives you the same loop from a terminal editor; Ctrl-B saves,
  builds, and runs the current file.

Luce also has a loadable `.lc` artifact and a small terminal runner for
development and distribution workflows. They are described later on this
page; you do not need them for your first program.

## Install a released toolchain

On macOS 15 or newer with Apple Silicon, or glibc Linux 2.28+ on x86-64 or
ARM64, install the current release with one command:

```sh
curl -fsSL https://luce.luciaos.com/install/0.18/install.sh | bash
```

The release ships `luce`, `loom`, `editor`, and their runtime libraries under
`~/.local/luce`. It also installs the Luce syntax extension into the local
VS Code, VS Code Insiders, or Cursor extension shelf, adds
`~/.local/luce/bin` to your shell's startup profile, and verifies the
downloaded archive before replacing an existing installation. Run it again
whenever you want a fresh copy. Open a new shell after installation, or
source the profile it reports; reload the editor to activate highlighting.

The installer chooses the archive from the operating system and architecture.
It refuses an unsupported machine, macOS older than 15, Linux with musl, a
Linux glibc older than 2.28, or a machine without a working `cc` before
changing an existing installation. On a missing linker it names the platform
package command to run and can then be rerun unchanged.

No released machine needs LLVM installed: it is linked into the compiler. A
machine that only runs `.lc` files does not invoke either LLVM or `cc`; native
linking happens when a source program is built.

The editor's Ctrl-B action uses the installed `luce` compiler beside it. The
host adds that tool directory when it starts a shell command, so the action
also works when the editor was opened from Finder or another launcher that did
not load your interactive shell profile.

## `luce` commands

```text
luce --version
luce --build-info
luce build [FILE] [-o OUT] [--release] [--emit=WHAT]
luce check FILE
luce query diagnostics FILE
luce ir FILE [--full]
luce test [PATH ...]
luce install
luce package NAME() [VERSION]
luce package version NAME VERSION
luce package publish NAME
```

`--version` prints the short tool version and exits. `--build-info` adds the
immutable source revision, target, optimization mode, serialized-module
format, and host ABI for a precise bug report. The compiler's command words
are `build`, `check`, `query`, `ir`, `test`, `install`, and `package`; the
runner's are `run` and `luce`.

`luce install` fills the package store from the manifest alone: a
`packages:` row carrying `url:` and `sha256:` is fetched, unpacked, hashed,
and moved into `.luce/packages/` in one rename — a row without the hash is
refused, a row already installed is verified and skipped, and nothing
half-fetched is ever left where imports resolve. See
[Packages](/tools/packages/).

`luce query diagnostics FILE` is the machine half of `check`: one JSON
array on standard output — `[]` for a clean compile, otherwise one
object per diagnostic with the stable `code`, the `message`, the
`path`, and 1-based `line`/`column`/`end_line`/`end_column`. FILE may
be `-` to read the source from standard input, which is how an editor
asks about a buffer it has not saved. A broken compile is still a
successful query (exit 0, the array is the answer); only a file the
query cannot read fails it.

`luce package new` creates a package in a direct source subfolder, writes its
`luce.yaml`, and adds a `path:` want to the project manifest. `luce package
version` updates the source manifest and root want together. `luce package
publish` is explicit about the current boundary: it refuses because no
package registry or upload protocol is configured yet.

`build` accepts a `.luc` source file, a `.lcm` intermediate module, or `-`
for standard input. Standard input needs `-o` because there is no source
name from which to derive an output path. With no file at all, `build`
builds the project. A `build.luc` beside the governing `luce.yaml` runs as
the project's build script: it is compiled through the ordinary cache, run
in the project root, and the plan it declares executes in dependency order
— see [std.build](/library/build/). Without a script, the manifest's
optional top-level `main:` key (`main: src/atlas.luc`) names the entry
program and the bare form expands to exactly the file form, options
unchanged. Without a governing manifest, or with neither `build.luc` nor
`main:`, the bare form refuses and says what to add. `check` type-checks without
writing an artifact. `ir` prints the verified Luce IR; `--full` keeps
functions that the normal build would prune. `test` is the test runner
described in [Testing](/tools/testing/).

For a `.luc` source, `build` defaults to a standalone executable named after
the source: `luce build hello.luc` writes `hello`. `-o` chooses a different
output path. `--release` removes source locations from runtime traps.
`--emit=library`, `--emit=object`, and `--emit=exe` choose the artifact shape;
`exe` is the default. Each option may be given once; a repeated option is
refused so a typo cannot silently select a different file or artifact kind.

## The three artifact shapes

| option | default output | use |
|---|---|---|
| `--emit=exe` | `FILE` | a standalone executable (the default) |
| `--emit=library` | `FILE.lc` | a native library that `loom run` loads |
| `--emit=object` | `FILE.o` | a relocatable object for a link step |

All three use the same front end, optimizer, LLVM backend, and runtime.
Artifacts record the target machine, host ABI, program hash, and code
generator. A loader refuses an artifact made for a different machine or
incompatible ABI instead of running it with the wrong assumptions.

The current `.lcm` format is **64** (`format_version = 64`) and the
published host ABI is **30** (`abi.version = 30`).
They describe compatibility of intermediate modules and host services, not
the user-facing release number. Current release label: **0.18**.

## `loom` commands

```text
loom --version
loom --build-info
loom                        interactive shell
loom run PROGRAM.lc [ARGS]
loom luce PROGRAM.luc [ARGS]
loom PROGRAM.lc [ARGS]      shorthand for run
```

`loom --build-info` prints the same release identity fields as the compiler.
`loom run` loads one `.lc` file and passes the remaining words to
`main(args)`. `loom luce` asks the `luce` compiler to build a `.luc` file,
then runs the resulting artifact; it caches that artifact beside the source
and rebuilds it when the source changes. A path ending in `.lc` or `.luc` may
also be given without the command word.

Loom's exit status distinguishes a finished program, a trap, an uncaught
error, an out-of-memory stop, and a refusal to run or write output. A trap is
not an error result: it indicates a violated language precondition and
includes its stable code. An uncaught error carries the error code and
message. See [Error Handling](/guide/errors/) for choosing between them.

## Debug and release

```text
luce build program.luc
luce build program.luc --release
```

Debug is the default. It keeps instruction origins, so a runtime trap can
show `file:line:column` and a call trace. `--release` strips those origins;
function names, trap codes, checks, and ARC behavior remain. The two
modes have the same observable semantics. Release is for artifacts whose
users do not have the source; debug is usually easier during development.
