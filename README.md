# Lucia

Hosted foundation for a document-native OS.

This repository starts deliberately small. The first layer is **durable
page storage** — not a filesystem, not documents, not encryption.

## Current scope

```text
Volume
 ├─ read page
 ├─ write page
 ├─ flush
 └─ geometry
      ↓
MemoryVolume / FileVolume / FaultyVolume
```

A page is a 4 KiB physical persistence unit. Higher layers (segments,
immutable objects, signed commits, document graph) will sit above
`Volume` and must never leak page addresses into document identity.

**Not in this layer yet**

- volume headers / checkpoints
- segments and object records
- document forest / paths
- encryption and key slots
- journal and acceptance rules

## Build

Requires C++23 (Clang 18+ or GCC 13+) and CMake 3.28+.

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build
ctest --test-dir build --output-on-failure
```

## Layout

```text
include/lucia/storage/     Volume contract and in-process backends
include/lucia/platform/    Host OS adapters (posix FileVolume)
src/                       Implementations
tests/storage/             Page I/O and fault-injection tests
```

Dependency rule: Lucia core depends on the `Volume` interface.
Platform code implements that interface. Core code does not include
OS headers.

## Language profile

Disciplined C++23:

- `std::span` for borrowed bytes
- `std::expected` for explicit errors
- value types, RAII, narrow virtual boundaries
- no exceptions as routine control flow
- no `shared_ptr` unless ownership is genuinely shared
