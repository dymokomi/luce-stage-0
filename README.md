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

The current host boundary supports macOS only and builds with the Apple Clang
toolchain provided by Xcode Command Line Tools. `first_lucia_test` exercises the
full proof flow from `docs/LOOM.md`: durable material in multiple arrangements,
computation, two Views, editing, restart, and an existing tool through a file
projection.

## Deferred scope

Production security, multi-user collaboration, Braid synchronization, permanent
history, replacement evaluation engines, and the agent remain deferred as
described in `docs/LOOM.md`.

## Packages

```text
src/base/                 shared primitive and container aliases
src/platform/io/          host file boundary
src/storage/volume/       page-volume contracts and implementations
src/fabric/model/         Texels, ports, fibers, values, and identities
src/fabric/persistence/   encoding and transactional durable store
src/realm/authority/      capabilities and authorization
src/loom/evaluation/      demand evaluation, State, and Delay
src/loom/effects/         effect protocol and trusted boundary
src/loom/organization/    arrangements
src/view/runtime/         evaluators and shell
src/projection/file/      manifests and file projection
apps/loom/                Loom command-line application
tests/                    grouped package and acceptance tests
docs/                     architecture and coding documentation
```
