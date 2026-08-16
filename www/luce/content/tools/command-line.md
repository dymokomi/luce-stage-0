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

On macOS with Apple Silicon, install the current release with one command:

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

The published toolchain is currently macOS ARM64 only. A machine that only
runs `.lc` files does not need LLVM; the released compiler already contains
what it needs to compile Luce programs.

The editor's Ctrl-B action uses the installed `luce` compiler beside it. The
host adds that tool directory when it starts a shell command, so the action
also works when the editor was opened from Finder or another launcher that did
not load your interactive shell profile.

## `luce` commands

```text
luce --version
luce build FILE [-o OUT] [--release] [--emit=WHAT]
luce check FILE
luce ir FILE [--full]
luce test [PATH ...]
luce package new NAME [VERSION]
luce package version NAME VERSION
luce package publish NAME
```

`--version` prints the tool version and exits. The compiler's command
words are `build`, `check`, `ir`, `test`, and `package`; the runner's are
`run` and `luce`.

`luce package new` creates a package in a direct source subfolder, writes its
`luce.yaml`, and adds a `path:` want to the project manifest. `luce package
version` updates the source manifest and root want together. `luce package
publish` is explicit about the current boundary: it refuses because no
package registry or upload protocol is configured yet.

`build` accepts a `.luc` source file, a `.lcm` intermediate module, or `-`
for standard input. Standard input needs `-o` because there is no source
name from which to derive an output path. `check` type-checks without
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

The current `.lcm` format is **55** (`format_version = 55`) and the
published host ABI is **24** (`abi.version = 24`).
They describe compatibility of intermediate modules and host services, not
the user-facing release number. Current release label: **0.18**.

## `loom` commands

```text
loom --version
loom                        interactive shell
loom run PROGRAM.lc [ARGS]
loom luce PROGRAM.luc [ARGS]
loom PROGRAM.lc [ARGS]      shorthand for run
```

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
