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
- durable arrangements; and
- manifest-driven file projection.

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
build/lucia open fabric.img
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
apps/lucia/                the lucia terminal
testdata/                 golden image fixtures
docs/                     architecture and coding documentation
build.sh  build.zig       ./build.sh installs, zig build test proves
```
