# Lucia Coding Guide

Write code that a tired reader can understand a week later.
Prefer plain, old-school C++ over clever modern ceremony.

`storage/` is the reference style. Match it.

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

Use the shared aliases in `storage/types.h`:

```cpp
Byte   // uint8_t
U32    // uint32_t
U64    // uint64_t
S64    // int64_t
Size   // size_t
Bytes  // std::vector<Byte>
```

Do not scatter raw `std::uint64_t`, `unsigned char`, or `std::vector<...>` through new code.
If a new common type is needed, add an alias in `types.h` first.

## Naming

### Functions are verbs

```cpp
count_pages()
read_page(...)
write_page(...)
flush_writes()
create_image(...)
open_image(...)
close_image()
contains_page(...)
byte_offset_for_page(...)
```

Getters that answer a question may also read as verbs: `count_pages()`, `is_open()`.

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

- Opening brace for functions goes on its own line
- Keep related declarations lined up when it helps scanning:

```cpp
bool read_page (U64 page_index, void*       destination);
bool write_page(U64 page_index, const void* source);
```

- Align nearby local declarations when natural:

```cpp
const S64 byte_offset = byte_offset_for_page(page_index);
const S64 bytes_read  = pread(file_handle, destination, PAGE_SIZE,
                              byte_offset);
```

- Two spaces of indent
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
// write_page is not durable until flush_writes succeeds
```

Bad:

```cpp
// increment i
// set fd to -1
```

## Organization

Top-level packages:

```text
platform/  storage/  crypto/  auth/  document/  network/  view/
gpu/       ui/       ai/      runtime/  apps/   tests/
```

Rules:

- One package, one job (see `README.md`)
- Put headers next to their `.cpp` files while a package is small
- One clear idea per file
- OS-specific code goes under `platform/macos`, `platform/linux`, or `platform/windows`
- Core packages do not include OS headers
- Public contracts stay small; implementation details stay private
- Do not add deeper nesting until a real boundary needs it

Dependency rule:

```text
apps → runtime → ui → gpu → platform
                  ai
                  view → document → crypto → storage → platform
                  auth → crypto
                  network → platform
```

`platform` is the bottom. `runtime` is what apps run inside.

## Classes and APIs

- Narrow interfaces
- Virtual boundaries only where substitution is real (`Volume`)
- No framework-style managers, factories, or abstract clutter
- Not copyable by default for resource owners
- Construction/setup methods should read clearly: `create_image`, `open_image`

A good API call site looks like:

```cpp
FileVolume volume;
volume.create_image("lucia.img", 1024);
volume.write_page(0, header_bytes);
volume.flush_writes();
```

## Errors

- Return `bool` for success/failure unless richer errors become necessary
- Fail early on bad arguments (`path == 0`, out-of-range page)
- Do not throw through storage code
- Do not hide durability: callers must call `flush_writes()` when durability matters

## Performance

- Keep the hot path obvious: `memcpy`, `pread`, `pwrite`, `fsync`
- No hidden allocations in `read_page` / `write_page`
- Page size is fixed (`PAGE_SIZE`); do not surprise callers with variable transfer sizes at this layer

## Tests

- Tests live under `tests/`
- Name test functions after what they prove: `test_memory_volume`, `test_file_volume`
- Prefer direct checks over heavy frameworks
- Cover success, bounds failure, and reopen/persistence where relevant

## What not to add casually

- Smart-pointer webs (`shared_ptr` especially)
- Template metaprogramming
- Operator overloading for cleverness
- Codegen / macros beyond simple test helpers
- Premature abstraction (fault injectors, platform trees, geometry structs) before a caller needs them

## Checklist for new code

1. Can a reader say what the file is for in one sentence?
2. Do functions read as verbs?
3. Are Lucia aliases used instead of raw stdint/std:: names?
4. Are members free of trailing underscores?
5. Are docs short and useful?
6. Is the hot path still visible?
7. Did we avoid adding a layer that is not needed yet?
