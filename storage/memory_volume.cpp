#include "memory_volume.h"

#include <string.h>

namespace lucia {

MemoryVolume::MemoryVolume(U64 pages)
    : pages(pages),
      bytes(static_cast<Size>(pages) * PAGE_SIZE, 0)
{
}

U64 MemoryVolume::count_pages() const
{
  return pages;
}

bool MemoryVolume::contains_page(U64 page_index) const
{
  return page_index < pages;
}

bool MemoryVolume::read_page(U64 page_index, void* destination)
{
  if (destination == 0 || !contains_page(page_index)) {
    return false;
  }

  const Size byte_offset = static_cast<Size>(page_index) * PAGE_SIZE;
  memcpy(destination, bytes.data() + byte_offset, PAGE_SIZE);
  return true;
}

bool MemoryVolume::write_page(U64 page_index, const void* source)
{
  if (source == 0 || !contains_page(page_index)) {
    return false;
  }

  const Size byte_offset = static_cast<Size>(page_index) * PAGE_SIZE;
  memcpy(bytes.data() + byte_offset, source, PAGE_SIZE);
  return true;
}

bool MemoryVolume::flush_writes()
{
  return true;
}

}  // namespace lucia
