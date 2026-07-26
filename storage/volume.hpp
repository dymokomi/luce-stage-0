#pragma once

#include <cstddef>
#include <cstdint>
#include <expected>
#include <span>

namespace lucia::storage {

inline constexpr std::uint32_t kPageSize = 4096;

enum class Error {
  OutOfRange,
  WrongSize,
  Io,
  Flush,
};

template <typename T>
using Result = std::expected<T, Error>;

struct Geometry {
  std::uint32_t page_size = kPageSize;
  std::uint64_t page_count = 0;
};

/// Fixed-size page store. Everything above this talks only to Volume.
class Volume {
 public:
  virtual ~Volume() = default;

  virtual Geometry geometry() const = 0;
  virtual Result<void> read(std::uint64_t page, std::span<std::byte> out) = 0;
  virtual Result<void> write(std::uint64_t page,
                             std::span<const std::byte> in) = 0;
  virtual Result<void> flush() = 0;
};

}  // namespace lucia::storage
