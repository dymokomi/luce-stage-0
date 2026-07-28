# LuciaOS

LuciaOS is building Loom, a single-user local engine for a persistent Fabric of
identity-bearing Texels connected by typed Fibers.

## Current milestone

The foundation provides:

- durable Texels;
- distinct typed `InputPort` and `OutputPort` structures;
- one input-owned Fiber binding per Input Port, with Output Port fan-out;
- transactional, crash-safe persistence;
- demand-driven, cached, acyclic evaluation.

The architecture and longer-term direction are described in
[planning/LOOM.md](planning/LOOM.md). Coding conventions are in
[CODING_GUIDE.md](CODING_GUIDE.md).

## Build and test

```sh
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
```

## Deferred scope

This milestone does not include Views, effects, capabilities, State or Delay
Texels, file projection, Braid, or production security. Those concerns should
not shape the foundation until the local durable and evaluable Fabric is sound.
