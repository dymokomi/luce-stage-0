# LuciaOS Coding Guide

Write code that a tired reader can understand a week later.
Prefer plain, old-school C++ over clever modern ceremony.

`reference/src/storage/volume/` is the reference style for C++. Match it.
North star for architecture: [LOOM.md](LOOM.md) (LuciaOS = OS; Loom = its
trusted local engine).

## Goals

- Simple
- Readable
- Fast
- Well organized
- Easy to return to after time away

If a change makes the architecture harder to see, do not merge it.

## Language

- C++17
- Headers use `.h`, not `.hpp`
- No exceptions for ordinary control flow
- No `[[nodiscard]]`, attributes, or similar noise
- No `std::expected`, `std::optional`, `std::span`, or heavy template machinery unless there is a clear local need
- Prefer `bool` success/failure at boundaries
- Prefer `void*` / `const void*` for raw page buffers
- Prefer C headers where they read cleaner (`stdint.h`, `string.h`, `stdio.h`)

## Types

Use the shared aliases in `reference/src/base/types.h` (the app carries its
own copy in `apps/loom/types.h`):

```cpp
Byte     // uint8_t
U32      // uint32_t
U64      // uint64_t
S64      // int64_t
Size     // size_t
String   // text
Bytes    // byte buffer
Strings  // list of strings
```

Do not write `std::` in ordinary Lucia code.  Wrap standard containers once with `typedef`, then use the alias:

```cpp
typedef std::map<String, InputPort> InputPortMap;
```

Those typedef lines are the only place `std::map` / `std::string` / `std::vector` should appear.  Everywhere else, say `InputPortMap`, `String`, `Bytes`.

Do not scatter raw `std::uint64_t`, `unsigned char`, or bare `std::vector<...>` through new code.  If a new common type is needed, add an alias in `types.h` first.

## Naming

### Drop the type noun when context already has it

The type or receiver already says what you are dealing with.  Do not repeat it in the function name:

```cpp
volume.read(page_index, destination);
volume.write(page_index, source);
volume.flush();
volume.create("lucia.img", 1024);
volume.open("lucia.img");
Value(true);                  // not Value::make_bool
value.boolean();              // not as_bool
output.set_value(Value("hello"));
texel.put(output);
```

### Collections use a small verb set

For tables and lists of items:

```cpp
size()
has(...)
get(...)
put(...)
remove(...)
at(...)
```

Prefer short names: `size()` not `count_elements()`, `put(...)` not `put_element(...)`.

### Other functions are short verbs

```cpp
read(...)
write(...)
flush()
create(...)
open(...)
close()
parse(...)
encode(...)
decode(...)
```

Getters that answer a question may read as verbs: `is_open()`, `is_unset()`, `has(...)`.

### Names are plain English

Prefer:

```cpp
file_handle
byte_offset
image_bytes
bytes_read
page_index
```

Avoid shorthand and platform-looking names in our code:

```cpp
fd, fd_
off, off_t
buf
n
ptr
```

POSIX calls may still appear in `.cpp` files. Wrap them immediately in clear local names.

### No trailing underscores

Members use plain names:

```cpp
U64   pages;
Bytes bytes;
int   file_handle;
```

Do not write `pages_`, `bytes_`, `file_handle_`.

If a parameter would shadow a member, rename the parameter (`image_pages`) or use `this->pages`.

## Formatting

- Every opening brace stays on the declaration or control-statement line.
- Use the root `.clang-format`; it specifies four-space indentation, attached
  braces, and a 92-column limit.
- Keep related declarations lined up when it helps scanning:

```cpp
bool read(U64 page_index, void* destination) {
    if (destination == 0) {
        return false;
    }
    // ...
}
```

- Align nearby local declarations when natural:

```cpp
const S64 offset     = byte_offset(page_index);
const S64 bytes_read = pread(file_handle, destination, PAGE_SIZE, offset);
```

- Four spaces of indent
- Keep functions short and boring

## Comments and docs

Document types and public methods with short section blocks:

```cpp
// ---------------------------------------------------------------------------
// FileVolume
// ---------------------------------------------------------------------------
//
// Page store backed by one host file (for example lucia.img).
//
```

Explain assumptions and ownership, not narration of obvious code.

Good:

```cpp
// write is not durable until flush succeeds
```

Bad:

```cpp
// increment i
// set fd to -1
```

## Organization

Current first-Lucia packages:

The Zig engine lives at the root (`loom/`, `abi/`, `testdata/`); the C++
reference tree keeps the layered packages:

```text
loom/  abi/  testdata/  apps/loom/  docs/
reference/src/base/  reference/src/platform/io/  reference/src/storage/volume/
reference/src/fabric/model/  reference/src/fabric/persistence/
reference/src/realm/authority/
reference/src/loom/evaluation/  reference/src/loom/effects/
reference/src/loom/organization/
reference/src/view/runtime/  reference/src/projection/file/
reference/tests/
```

Durable Texels, typed Ports, Fibers, and values belong in `fabric/model/`.
Encoding and transactional persistence belong in `fabric/persistence/`.
Page storage and durability mechanics belong in `storage/volume/`.
Capabilities belong in `realm/authority/`. Evaluation, State/Delay,
effects, and arrangements belong in their narrow `loom/` packages. The CLI
lives in `apps/loom/`. Views and file projection live in `view/runtime/`
and `projection/file/`. The Zig engine mirrors the same package layout
under `loom/`.

Production security, collaboration, Braid, permanent history, replacement
engines, and the agent remain deferred.

Rules:

- One package, one job
- Put headers next to their `.cpp` files
- One clear idea per file
- Public contracts stay small; implementation details stay private

Dependency rule:

```text
projection / view → loom → realm / fabric → storage → platform
tests → the package under test
```

Keep storage independent of Fabric concepts. Keep deferred systems out of this
dependency chain.

## Classes and APIs

- Narrow interfaces
- Virtual boundaries only where substitution is real (`Volume`)
- No framework-style managers, factories, or abstract clutter
- Not copyable by default for resource owners
- Construction/setup methods should read clearly: `create`, `open`

A good API call site looks like:

```cpp
FileVolume volume;
volume.create("lucia.img", 1024);
volume.write(0, header_bytes);
volume.flush();

Texel texel;
texel.set_id(id);
texel.put(OutputPort("out", VALUE_TEXT));
```

## Errors

- Return `bool` for success/failure unless richer errors become necessary
- Fail early on bad arguments (`name == 0`, out-of-range page)
- Do not throw through storage or fabric code
- Do not hide durability: callers must call `flush()` when durability matters

## Performance

- Keep the hot path obvious: `memcpy`, `pread`, `pwrite`, `fsync`
- No hidden allocations in `read` / `write`
- Page size is fixed (`PAGE_SIZE`); do not surprise callers with variable transfer sizes at this layer

## Tests

- C++ tests live under the matching package in `reference/tests/`; Zig
  tests are `test` blocks beside the code they prove
- Name test functions after what they prove: `test_memory_volume`, `test_file_volume`
- Prefer direct checks over heavy frameworks
- Cover success, bounds failure, and reopen/persistence where relevant

## What not to add casually

- Smart-pointer webs (`shared_ptr` especially)
- Template metaprogramming
- Operator overloading for cleverness
- Codegen / macros beyond simple test helpers
- Premature abstraction before a caller needs it
- Redundant type nouns in names (`put_port`, `count_pages` on a page volume — prefer `put`, `size`)
- Leaking `std::map` / `std::vector` / `std::string` in public APIs

## Checklist for new code

1. Can a reader say what the file is for in one sentence?
2. Are names short, with no redundant type nouns?
3. Are Lucia aliases used instead of raw stdint/`std::` names?
4. Are members free of trailing underscores?
5. Are docs short and useful?
6. Is the hot path still visible?
7. Did we avoid adding a layer that is not needed yet?
