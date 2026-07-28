#include "memory_volume.h"

#include <string.h>

namespace lucia {

MemoryVolume::MemoryVolume(U64 pages)
    : pages(pages),
      bytes(static_cast<Size>(pages) * PAGE_SIZE, 0)
{
}

U64 MemoryVolume::size() const
{
  return pages;
}

bool MemoryVolume::contains(U64 page_index) const
{
  return page_index < pages;
}

bool MemoryVolume::read(U64 page_index, void* destination)
{
  if (destination == 0 || !contains(page_index)) {
    return false;
  }

  const Size byte_offset = static_cast<Size>(page_index) * PAGE_SIZE;
  memcpy(destination, bytes.data() + byte_offset, PAGE_SIZE);
  return true;
}

bool MemoryVolume::write(U64 page_index, const void* source)
{
  if (source == 0 || !contains(page_index)) {
    return false;
  }

  const Size byte_offset = static_cast<Size>(page_index) * PAGE_SIZE;
  memcpy(bytes.data() + byte_offset, source, PAGE_SIZE);
  return true;
}

bool MemoryVolume::flush()
{
  return true;
}

}  // namespace lucia
