#pragma once

#include <stdint.h>

namespace lucia {

enum { PAGE_SIZE = 4096 };

// Fixed-size page store. Higher layers talk only to this.
class Volume {
public:
  virtual ~Volume() {}

  virtual uint64_t pages() const = 0;
  virtual bool read(uint64_t page, void* buf) = 0;
  virtual bool write(uint64_t page, const void* buf) = 0;
  virtual bool flush() = 0;
};

}  // namespace lucia
