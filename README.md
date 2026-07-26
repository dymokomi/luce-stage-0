# Lucia

Document-native OS, built from storage upward.

## Right now

A `Volume` is a store of fixed 4 KiB pages.

```text
Volume
  read / write / flush
       |
MemoryVolume     FileVolume
```

No filesystem yet.

## Layout

```text
storage/
  volume.hpp
  memory_volume.*
  file_volume.*
tests/
  volume_test.cpp
```

## Build

```bash
cmake -S . -B build -DCMAKE_CXX_COMPILER=g++
cmake --build build
ctest --test-dir build --output-on-failure
```
