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

The Loom engine is written in Zig 0.16 (`loom/`) behind the C ABI in
`abi/loom.h`; the engine suite and the C ABI smoke test run on any host OS:

```sh
zig build test
```

The full build — the C++ reference tree plus the `loom` terminal, which links
the Zig engine through the ABI — is driven by CMake (it runs `zig build`
automatically, so Zig 0.16 must be on PATH):

```sh
cmake -S . -B build/debug
cmake --build build/debug
ctest --test-dir build/debug --output-on-failure
```

To verify with runtime sanitizers:

```sh
cmake -S . -B build/sanitize -DLUCIA_SANITIZE=ON
cmake --build build/sanitize
ctest --test-dir build/sanitize --output-on-failure
```

The CMake host boundary supports macOS only and builds with the Apple Clang
toolchain provided by Xcode Command Line Tools. `first_lucia_test` exercises the
full proof flow from `docs/LOOM.md`: durable material in multiple arrangements,
computation, two Views, editing, restart, and an existing tool through a file
projection. The on-disk image format is the frozen contract between the two
engine trees; `testdata/golden_store.bin` must open in both (see
[docs/ZIG.md](docs/ZIG.md)).

## Deferred scope

Production security, multi-user collaboration, Braid synchronization, permanent
history, replacement evaluation engines, and the agent remain deferred as
described in `docs/LOOM.md`.

## Packages

```text
loom/                     the Loom engine (Zig): storage, fabric,
                          evaluation, organization, effects, authority
loom/abi.zig              implementation of the C ABI border
abi/                      loom.h, the constitutional C border, and its
                          C smoke test
testdata/                 golden image fixtures shared by both engines
apps/loom/                the Loom terminal (C++, speaks only abi/loom.h)
reference/src/            the C++ reference engine, layered as
                          platform → storage → fabric → realm → loom →
                          view / projection
reference/tests/          grouped package and acceptance tests for the
                          reference engine
docs/                     architecture and coding documentation
build.zig                 engine build: zig build test, zig build
CMakeLists.txt            full build: reference tree + terminal
```
