#pragma once

#include "volume.h"

namespace lucia {

// ---------------------------------------------------------------------------
// MemoryVolume
// ---------------------------------------------------------------------------
//
// In-process page store.  Useful for tests.  flush_writes() always succeeds
// because memory is already as durable as the process itself.
//
class MemoryVolume : public Volume {
public:
  explicit MemoryVolume(U64 pages);

  U64 count_pages() const override;

  bool read_page (U64 page_index, void*       destination) override;
  bool write_page(U64 page_index, const void* source)      override;
  bool flush_writes() override;

private:
  bool contains_page(U64 page_index) const;

  U64   pages;
  Bytes bytes;
};

}  // namespace lucia
