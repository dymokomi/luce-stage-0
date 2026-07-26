# Lucia

A document-native OS, built slowly from the storage up.

## Right now

One idea: a `Volume` is a store of fixed 4 KiB pages.

```text
Volume
  read(page) / write(page) / flush()
       ↓
MemoryVolume    FileVolume
(tests)         (lucia.img)
```

No filesystem, documents, segments, or encryption yet.

## Layout

```text
storage/
  volume.hpp          contract
  memory_volume.*     in-memory backend
  file_volume.*       host-file backend
tests/
  volume_test.cpp
```

## Build

```bash
cmake -S . -B build -DCMAKE_CXX_COMPILER=g++
cmake --build build
ctest --test-dir build --output-on-failure
```
