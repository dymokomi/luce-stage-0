#pragma once

#include "storage/volume/volume.h"

namespace lucia {

// ---------------------------------------------------------------------------
// MemoryVolume
// ---------------------------------------------------------------------------
//
// In-process page store.  Useful for tests.  flush() always succeeds
// because memory is already as durable as the process itself.
//
class MemoryVolume : public Volume {
public:
  explicit MemoryVolume(U64 pages);

  U64 size() const override;

  bool read(U64 page_index, void *destination) override;
  bool write(U64 page_index, const void *source) override;
  bool flush() override;

private:
  bool contains(U64 page_index) const;

  U64   pages;
  Bytes bytes;
};

} // namespace lucia
