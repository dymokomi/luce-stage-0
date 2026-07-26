#pragma once

#include <vector>

#include "volume.hpp"

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
  explicit MemoryVolume(uint64_t page_count);

  uint64_t page_count() const override;

  bool read_page (uint64_t page_index, void*       destination) override;
  bool write_page(uint64_t page_index, const void* source)      override;
  bool flush_writes() override;

private:
  bool contains_page(uint64_t page_index) const;

  uint64_t                   page_count_;
  std::vector<unsigned char> bytes_;
};

}  // namespace lucia
