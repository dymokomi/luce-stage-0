#pragma once

#include <stdint.h>

namespace lucia {

// ---------------------------------------------------------------------------
// Page size
// ---------------------------------------------------------------------------
//
// Every volume is a sequence of fixed pages.  Higher layers (segments,
// objects, documents) address storage only through this unit.
//
enum { PAGE_SIZE = 4096 };

// ---------------------------------------------------------------------------
// Volume
// ---------------------------------------------------------------------------
//
// A durable store of pages.  Callers may assume:
//
//   - read_page / write_page move exactly PAGE_SIZE bytes
//   - write_page is not durable until flush_writes succeeds
//   - page_index is in [0, page_count())
//
class Volume {
public:
  virtual ~Volume() {}

  virtual uint64_t page_count() const = 0;

  virtual bool read_page (uint64_t page_index, void*       destination) = 0;
  virtual bool write_page(uint64_t page_index, const void* source)      = 0;
  virtual bool flush_writes() = 0;
};

}  // namespace lucia
