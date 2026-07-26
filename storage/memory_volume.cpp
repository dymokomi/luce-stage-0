#include "memory_volume.hpp"

#include <string.h>

namespace lucia {

MemoryVolume::MemoryVolume(uint64_t page_count)
    : pages_(page_count),
      data_(static_cast<size_t>(page_count) * PAGE_SIZE, 0) {}

uint64_t MemoryVolume::pages() const {
  return pages_;
}

bool MemoryVolume::read(uint64_t page, void* buf) {
  if (!buf || page >= pages_) {
    return false;
  }
  memcpy(buf, data_.data() + page * PAGE_SIZE, PAGE_SIZE);
  return true;
}

bool MemoryVolume::write(uint64_t page, const void* buf) {
  if (!buf || page >= pages_) {
    return false;
  }
  memcpy(data_.data() + page * PAGE_SIZE, buf, PAGE_SIZE);
  return true;
}

bool MemoryVolume::flush() {
  return true;
}

}  // namespace lucia
