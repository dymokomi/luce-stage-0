#pragma once

#include "base/types.h"

namespace lucia {

// ---------------------------------------------------------------------------
// Page size
// ---------------------------------------------------------------------------
//
// Every volume is a sequence of fixed pages.  Higher layers (fabric graph,
// journal) address storage only through this unit.
//
enum { PAGE_SIZE = 4096 };

// ---------------------------------------------------------------------------
// Volume
// ---------------------------------------------------------------------------
//
// A durable store of pages.  Callers may assume:
//
//   - read / write move exactly PAGE_SIZE bytes
//   - write is not durable until flush succeeds
//   - page_index is in [0, size())
//
class Volume {
public:
  virtual ~Volume() {}

  virtual U64 size() const = 0;

  virtual bool read(U64 page_index, void *destination)   = 0;
  virtual bool write(U64 page_index, const void *source) = 0;
  virtual bool flush()                                   = 0;
};

} // namespace lucia
