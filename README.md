# Lucia

Document-native OS, built from storage upward.

## Right now

A `Volume` is a store of fixed 4 KiB pages.

```text
Volume
  count_pages / read_page / write_page / flush_writes
                     |
            MemoryVolume       FileVolume
```

No filesystem yet.

## Layout

```text
storage/
  types.hpp            Byte, U64, S64, Size, Bytes
  volume.hpp           contract
  memory_volume.*      in-memory pages
  file_volume.*        host-file pages (lucia.img)
tests/
  volume_test.cpp
```

## Build

```bash
cmake -S . -B build -DCMAKE_CXX_COMPILER=g++
cmake --build build
ctest --test-dir build --output-on-failure
```
