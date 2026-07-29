# LuciaOS

LuciaOS is building Loom, a single-user local engine for a persistent Fabric of
identity-bearing Texels connected by typed Fibers.

## Current milestone

The first Lucia scope provides:

- durable Texels;
- distinct typed `InputPort` and `OutputPort` structures;
- one input-owned Fiber binding per Input Port, with Output Port fan-out;
- transactional, crash-safe persistence;
- demand-driven, cached, acyclic evaluation;
- durable State and Delay evaluation;
- explicit effects guarded by capabilities;
- Views and a shell runtime;
- durable arrangements;
- manifest-driven file projection; and
- Luce, the small native language that makes Texels compute
  ([docs/LUCE.md](docs/LUCE.md)), with fabric builtins so template
  texels can weave new texels and capability-gated file builtins for
  explicitly connected directory-relative reads; and
- a Fabric-native full-screen content editor: Luce owns buffer behavior
  in an ordinary bootstrap-created `editor` Texel, while a generic
  trusted terminal shell renders its plain-text View frames.

The architecture and longer-term direction are described in
[docs/LOOM.md](docs/LOOM.md). Coding conventions are in
[docs/CODING_GUIDE.md](docs/CODING_GUIDE.md).

## Build and test

Everything is Zig 0.16 (see [docs/ZIG.md](docs/ZIG.md)) and runs on any
host OS:

```sh
./build.sh         # installs the lucia terminal at build/lucia and libloom.a at build/lib/
zig build test     # engine suite + terminal suite + C ABI smoke test
```

`loom/first_lucia_test.zig` exercises the full proof flow from
`docs/LOOM.md`: durable material in multiple arrangements, computation, two
Views, editing, restart, and an existing tool through a file projection.
The on-disk image format is frozen; the golden fixture
`testdata/golden_store.bin` must always open unchanged.

Try it:

```sh
build/lucia create fabric.img
build/lucia open fabric.img --luce bootstrap/editor.luc # install the editor Texel
build/lucia open fabric.img                            # interactive terminal
```

Hosted scripts receive directory authority only for the directory containing
the script. `script_directory()` returns that authority as `Bytes`, and the
general `read_file(capability: Bytes, path: String) -> String` builtin uses an
explicit capability to read one regular sibling file. Missing host authority,
foreign capabilities, path traversal, links, and failed reads trap without
applying Fabric intents.

Ordinary Luce uses the same reader but receives no ambient grant. Issue a
session-local capability texel, connect its `capability` Bytes output to an
explicit Input Port, and pass that input to `read_file`:

```text
lucia> allow-read documents document-files
lucia document-files> select reader
lucia reader> connect capability document-files capability
```

`allow-read DIRECTORY NAME` resolves `DIRECTORY` relative to the directory
where `lucia` was opened. The token remains encoded in the Fabric, but its
grant is deliberately volatile: it is valid only in that terminal session and
denies after restart until a trusted boundary issues a new grant.

The editor bootstrap is split deliberately: `bootstrap/editor.luc` defines the
Texel schema and reads `bootstrap/editor_view.luc`, while `editor_view.luc` is
the readable evaluator source persisted as the editor Texel's content.

Inside the terminal, edit another Texel's content with the installed
editor View:

```text
lucia> luce editor TARGET
```

The invocation resolves `TARGET` once, gives Luce only its content and
label, and keeps a capability scoped to saving that exact Texel at the
trusted boundary. Fabric builtins are disabled while evaluating frames.
`Ctrl-S` saves and `Ctrl-Q` quits.

A Texel computes with Luce source:

```text
lucia> new doubler
lucia doubler> input value int
lucia doubler> output value int
lucia doubler> eval luce
lucia doubler> code
enter luce source; finish with a single .
... func evaluate(input: Input, output: Output):
...     output.value = input.value * 2
... .
lucia doubler> connect value SOURCE value
lucia doubler> pull value
```

## Deferred scope

Production security, multi-user collaboration, Braid synchronization, permanent
history, replacement evaluation engines, and the agent remain deferred as
described in `docs/LOOM.md`.

## Packages

```text
loom/                     the Loom engine: storage, fabric, evaluation,
                          organization, effects, authority, view,
                          projection
loom/abi.zig              implementation of the C ABI border
abi/                      loom.h, the constitutional C border, and its
                          C smoke test
luce/                     the Luce compiler: lexer, parser, analyzer,
                          typed IR, and the execution boundary
apps/lucia/               the lucia terminal
bootstrap/                Luce scripts that install system Texels
testdata/                 golden image fixtures
docs/                     architecture and coding documentation
build.sh  build.zig       ./build.sh installs, zig build test proves
```
