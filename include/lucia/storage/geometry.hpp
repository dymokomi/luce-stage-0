#pragma once

#include <cstdint>

#include "lucia/storage/page.hpp"

namespace lucia::storage {

/// Properties that affect storage correctness.
/// Do not hide these behind a falsely simple "save bytes" API.
struct Geometry {
  std::uint32_t page_size = kDefaultPageSize;
  std::uint64_t page_count = 0;

  /// Minimum alignment required for transfer buffers, in bytes.
  std::uint32_t required_alignment = 1;

  /// Largest contiguous transfer the backend prefers, in bytes.
  /// Page remains the addressing unit; this is a performance hint.
  std::uint32_t max_transfer_size = kDefaultPageSize;

  /// Largest write the backend claims is power-fail atomic, in bytes.
  /// Zero means the backend makes no atomicity promise.
  std::uint32_t atomic_write_size = 0;

  /// True when flush() is a real durability barrier.
  bool flush_supported = true;
};

}  // namespace lucia::storage
