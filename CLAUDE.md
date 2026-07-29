# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Workflow

Single-developer project: commit directly to `main` (no PRs, no feature branches) with git author `Dy Mokomi <dy@dymokomi.com>`.

## Build and test

The build supports **macOS only** (CMake fails fatally on other platforms) with the Apple Clang toolchain from Xcode Command Line Tools.

```sh
cmake -S . -B build/debug
cmake --build build/debug
ctest --test-dir build/debug --output-on-failure
```

Sanitizer build (UBSan on macOS):

```sh
cmake -S . -B build/sanitize -DLUCIA_SANITIZE=ON
cmake --build build/sanitize
ctest --test-dir build/sanitize --output-on-failure
```

Run a single test with `ctest --test-dir build/debug -R spool_test`, or execute the test binary directly (e.g. `./build/debug/spool_test`). Each test is a standalone executable registered via the `lucia_test()` function in `CMakeLists.txt` — a new test file must be added there. `first_lucia_test` is the acceptance test proving the full flow from `docs/LOOM.md`. `loom_demo` runs the CLI (`loom demo`) as a test.

Formatting is enforced by the root `.clang-format` (LLVM base, 4-space indent, attached braces, 92-column limit, aligned consecutive assignments/declarations).

## What this project is

LuciaOS is building **Loom**, a single-user local engine for a persistent **Fabric** of identity-bearing **Texels** connected by typed **Fibers**. The user-visible ontology is deliberately tiny (Texel, Port, Fiber, View); everything else is implementation machinery. Read `docs/LOOM.md` before making architectural decisions — it is the north star, and "if a change makes the architecture harder to see, do not merge it."

Deferred by design (do not build toward these): production security, multi-user collaboration, Braid synchronization, permanent history, replacement evaluation engines, and the agent.

## Architecture

Strict layered dependency chain — lower layers must not know about higher ones, and storage must stay independent of Fabric concepts:

```text
projection / view → loom → realm / fabric → storage → platform
tests → the package under test
```

Each layer is a CMake static library (`lucia_platform`, `lucia_storage`, `lucia_fabric`, `lucia_realm`, `lucia_loom`, `lucia_view`, `lucia_projection`) plus the `loom` CLI executable in `apps/loom/`.

- **`src/platform/`** — host boundary. `platform/io/file.h` is the contract; `platform/macos/file.cpp` is the only implementation.
- **`src/storage/volume/`** — fixed-size page stores. `Volume` is the one virtual interface (real substitution: `FileVolume`, `MemoryVolume`). **This package is the reference coding style — match it.**
- **`src/fabric/model/`** — `Texel`, `TexelId`, `InputPort`, `OutputPort`, `Fiber`, `Value`, `ValueOutcome`, `BlobRef`. `InputPort` and `OutputPort` are distinct types because they own different state: an InputPort owns its single incoming Fiber binding; an OutputPort owns its value/revision/cache state and may fan out to many inputs.
- **`src/fabric/persistence/`** — `Store` (durable Texel snapshot using two descriptor pages and two body arenas, published atomically by generation) and `Transaction` (private working snapshot; `connect`/`disconnect`/`put`/`put_blob`, visible only after `commit`). Large content goes out of line as blobs behind `BlobRef`.
- **`src/realm/authority/`** — capabilities. Sensitive operations require an explicit capability value arriving at an Input Port; there is no ambient access.
- **`src/loom/`** — `evaluation/spool.h`: demand-driven, cached, acyclic evaluation. `Spool` is a *disposable* cache over a read-only `Store` plus a non-owning `EvaluatorRegistry`; evaluators are pure and keyed by persisted name. Recurrence only enters through explicit State/Delay (`state.h`). `effects/`: effect intents as data, performed once at a trusted boundary. `organization/`: arrangements (Texels whose inputs name/order other Texels).
- **`src/view/runtime/`** — Views are ordinary Texels whose computation produces an interface; `shell.h` is the small trusted shell that demands, composites, and routes input.
- **`src/projection/file/`** — manifest-driven projection of a Fabric region into files for existing tools.

Direction of demand is opposite to direction of value: a View demands an output, the Spool pulls upstream outputs, runs evaluators, and caches by revision. Nothing recomputes merely because it exists.

The `loom` app has two boundaries: a setup boundary (`loom create IMAGE [--pages N]`) and a load boundary (`loom open IMAGE`) that drops into an interactive terminal (`loom>` prompt) over the opened Fabric. Terminal commands: `new NAME`, `rename ID NAME`, `find TEXT`, `delete ID`, `list`, `help`, `exit`. A texel's name is deliberately not part of identity — it is a text value on the `name` Output Port. The app is organized as `command_line.h` (process-argument parser plus `split_words`, a quote-aware line tokenizer), `image.h` (opens one volume + Fabric store), `terminal.h` (the read-dispatch loop; prompt only when stdin is a tty), `command.h` (the virtual `Command` interface: `name`/`argument_count`/`usage`/`run`), `command_set.h` (owns one instance of every command; dispatches and arity-checks), and `commands/` (one `.h`/`.cpp` pair per command, named after the command alone — `commands/new.h`, not `new_command.h` — plus `commands/common.h` shared helpers). To add a terminal command: create its pair in `commands/`, register it as a member + table entry in `command_set.h/.cpp`, and add the `.cpp` to `CMakeLists.txt`. The `loom_terminal` ctest scripts a session through the real binary.

## Coding conventions

`docs/CODING_GUIDE.md` is authoritative and intentionally opinionated — plain, old-school C++ over modern ceremony. The essentials:

- C++17; headers use `.h`, placed next to their `.cpp`; no exceptions for ordinary control flow; return `bool` for success/failure; fail early on bad arguments; never hide durability (callers call `flush()`).
- **Never write `std::` in ordinary Lucia code.** Use the aliases from `src/base/types.h` (`Byte`, `U32`, `U64`, `S64`, `Size`, `String`, `Bytes`, `Strings`). Wrap other standard containers once with a `typedef` (e.g. `typedef std::map<String, InputPort> InputPortMap;`) and use the alias everywhere else. New common types get an alias in `types.h` first.
- No `[[nodiscard]]`, `std::optional`/`expected`/`span`, smart-pointer webs (especially `shared_ptr`), template metaprogramming, operator-overloading cleverness, factories/managers, or premature abstraction. Virtual boundaries only where substitution is real (`Volume`, `Evaluator`).
- Naming: short verbs (`read`, `write`, `open`, `parse`, `encode`); collections use `size`/`has`/`get`/`put`/`remove`/`at`; drop redundant type nouns (`volume.read(...)`, not `read_page`); plain-English names (`file_handle`, `page_index` — never `fd`, `buf`, `n`, `ptr`); **no trailing underscores on members** (`pages`, not `pages_`; rename a shadowing parameter or use `this->`).
- Prefer C headers where they read cleaner (`stdint.h`, `string.h`, `stdio.h`). POSIX calls may appear in `.cpp` files but wrap results immediately in clear local names.
- Comments: short section blocks (dashed-line header + one-sentence purpose) over types and public methods; explain assumptions and ownership, not obvious code.
- Keep the hot path visible: `memcpy`, `pread`, `pwrite`, `fsync`; no hidden allocations in `read`/`write`; page size is fixed (`PAGE_SIZE`).
- Tests: direct checks, no framework; test functions named after what they prove (`test_file_volume`); cover success, bounds failure, and reopen/persistence where relevant.
