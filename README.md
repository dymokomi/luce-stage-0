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
[planning/LOOM.md](planning/LOOM.md). Coding conventions are in
[CODING_GUIDE.md](CODING_GUIDE.md).

## Build and test

```sh
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
```

The current host boundary targets macOS. `first_lucia_test` exercises the full
proof flow from `planning/LOOM.md`: durable material in multiple arrangements,
computation, two Views, editing, restart, and an existing tool through a file
projection.

## Deferred scope

Production security, multi-user collaboration, Braid synchronization, permanent
history, replacement evaluation engines, and the agent remain deferred as
described in `planning/LOOM.md`.

## Packages

```text
base/                 shared primitive and container aliases
platform/io/          host file boundary
storage/volume/       page-volume contracts and implementations
fabric/model/         Texels, ports, fibers, values, and identities
fabric/persistence/   encoding and transactional durable store
realm/authority/      capabilities and authorization
loom/evaluation/      demand evaluation, State, and Delay
loom/effects/         effect protocol and trusted boundary
loom/organization/    arrangements
loom/cli/             command-line parsing and commands
view/runtime/         evaluators and shell
projection/file/      manifests and file projection
```
