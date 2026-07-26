#include "memory_volume.hpp"

#include <string.h>

namespace lucia {

MemoryVolume::MemoryVolume(uint64_t pages)
    : pages(pages),
      bytes(static_cast<size_t>(pages) * PAGE_SIZE, 0)
{
}

uint64_t MemoryVolume::count_pages() const
{
  return pages;
}

bool MemoryVolume::contains_page(uint64_t page_index) const
{
  return page_index < pages;
}

bool MemoryVolume::read_page(uint64_t page_index, void* destination)
{
  if (destination == 0 || !contains_page(page_index)) {
    return false;
  }

  const size_t byte_offset = static_cast<size_t>(page_index) * PAGE_SIZE;
  memcpy(destination, bytes.data() + byte_offset, PAGE_SIZE);
  return true;
}

bool MemoryVolume::write_page(uint64_t page_index, const void* source)
{
  if (source == 0 || !contains_page(page_index)) {
    return false;
  }

  const size_t byte_offset = static_cast<size_t>(page_index) * PAGE_SIZE;
  memcpy(bytes.data() + byte_offset, source, PAGE_SIZE);
  return true;
}

bool MemoryVolume::flush_writes()
{
  return true;
}

}  // namespace lucia
