# Lucia

Document-native OS, built from storage upward.

Style rules: [CODING_GUIDE.md](CODING_GUIDE.md).

## Layout

```text
storage/     Low-level page/block store (Volume)
document/    Document model — Lucia's filesystem
crypto/      Encryption and authenticity for stored documents
auth/        User authentication; unlocks crypto for read/write
network/     Networking
view/        Filtered / composed / mutated document views
platform/    OS adapters so the rest stays portable
  macos/
  linux/
  windows/
ai/          AI / LLM code
gpu/         Fast compute and rendering surface
ui/          User interface
apps/        CLI tools that manage the system
  realm/
  terminal/
  system/
tests/       Unit and integration tests
```

### Package roles

| Package    | Responsibility |
| ---------- | -------------- |
| `storage`  | Fixed pages. No documents, paths, or encryption. |
| `document` | Document graph identity, versions, containment, connections. |
| `crypto`   | Keys, encrypt/decrypt, sign/verify for document bytes. |
| `auth`     | Who is acting; unlocks and authorizes crypto use. |
| `network`  | Transports and sync protocols. |
| `view`     | Read-time filtering, composition, and mutation over documents. |
| `platform` | macOS / Linux / Windows adapters (files, clocks, entropy, etc.). |
| `ai`       | Model clients, prompts, and AI-assisted flows. |
| `gpu`      | GPU compute and rendering abstraction. |
| `ui`       | Interactive UI built on documents, views, and gpu. |
| `apps`     | User-facing CLI programs: `realm`, `terminal`, `system`. |

### Dependency direction

```text
apps → ui / ai / view / document / auth / network
         ↓
   document → crypto → storage
         ↓
      platform → (macos | linux | windows)
```

Higher packages may depend on lower ones.
`storage` and `platform` must not depend on `document`, `ui`, or `apps`.
Core packages should not include OS headers; that stays in `platform/`.

## Right now

Implemented:

```text
storage/
  types.hpp
  volume.hpp
  memory_volume.*
  file_volume.*      (POSIX host file; will move under platform later)
tests/
  volume_test.cpp
```

Everything else is scaffolded for the next layers.

## Build

```bash
cmake -S . -B build -DCMAKE_CXX_COMPILER=g++
cmake --build build
ctest --test-dir build --output-on-failure
```
