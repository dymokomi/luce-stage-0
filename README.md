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
runtime/     Environment that loads and runs Lucia apps
apps/        Programs written for Lucia
  realm/
  terminal/
  system/
tests/       Unit and integration tests
```

### Package roles

| Package    | Responsibility |
| ---------- | -------------- |
| `platform` | macOS / Linux / Windows adapters: files, clocks, entropy, sockets, windows. |
| `storage`  | Durable pages, built on platform I/O. No documents or encryption. |
| `crypto`   | Keys, encrypt/decrypt, sign/verify for document bytes. |
| `auth`     | Who is acting; unlocks and authorizes crypto use. |
| `document` | Document graph identity, versions, containment, connections. |
| `network`  | Transports and sync protocols, built on platform sockets. |
| `view`     | Read-time filtering, composition, and mutation over documents. |
| `gpu`      | GPU compute and rendering, built on platform graphics. |
| `ui`       | Interactive UI, built on gpu (and usually view/document). |
| `ai`       | Model clients, prompts, and AI-assisted flows. |
| `runtime`  | App environment: launch, services, lifecycle, capabilities. |
| `apps`     | Lucia programs: `realm`, `terminal`, `system`. |

### Why `runtime`

`apps/` are the programs. `runtime/` is the OS-side environment that runs them:

- start and stop apps
- hand them storage, document, network, ui, ai services
- enforce auth/capabilities
- own the main loop / process model as Lucia becomes more OS-like

Without `runtime`, that wiring tends to leak into `apps/` or `platform/`.

### Dependency direction

```text
apps
  ↓
runtime
  ↓
ui --------→ gpu --------→ platform
ai
view ------→ document → crypto → storage → platform
auth ------→ crypto
network ------------------------------→ platform
```

Rules:

- Higher packages may depend on lower ones.
- `platform` depends on nothing else in Lucia.
- `storage`, `network`, and `gpu` depend on `platform`.
- `ui` depends on `gpu` (not the other way around).
- `runtime` wires services for apps; apps should not reach into `platform` directly.
- Core packages do not include OS headers; that stays in `platform/`.

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
