#pragma once

#include <vector>

#include "volume.hpp"

namespace lucia {

class MemoryVolume : public Volume {
public:
  explicit MemoryVolume(uint64_t page_count);

  uint64_t pages() const;
  bool read(uint64_t page, void* buf);
  bool write(uint64_t page, const void* buf);
  bool flush();

private:
  uint64_t pages_;
  std::vector<unsigned char> data_;
};

}  // namespace lucia
