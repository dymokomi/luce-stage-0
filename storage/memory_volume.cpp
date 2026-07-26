#include "memory_volume.hpp"

#include <cstring>

namespace lucia::storage {

MemoryVolume::MemoryVolume(std::uint64_t page_count) {
  geo_.page_count = page_count;
  data_.assign(static_cast<std::size_t>(page_count) * kPageSize, std::byte{0});
}

Geometry MemoryVolume::geometry() const {
  return geo_;
}

Result<void> MemoryVolume::check(std::uint64_t page, std::size_t size) const {
  if (size != kPageSize) {
    return std::unexpected(Error::WrongSize);
  }
  if (page >= geo_.page_count) {
    return std::unexpected(Error::OutOfRange);
  }
  return {};
}

Result<void> MemoryVolume::read(std::uint64_t page, std::span<std::byte> out) {
  if (auto s = check(page, out.size()); !s) {
    return s;
  }
  std::memcpy(out.data(), data_.data() + page * kPageSize, kPageSize);
  return {};
}

Result<void> MemoryVolume::write(std::uint64_t page,
                                 std::span<const std::byte> in) {
  if (auto s = check(page, in.size()); !s) {
    return s;
  }
  std::memcpy(data_.data() + page * kPageSize, in.data(), kPageSize);
  return {};
}

Result<void> MemoryVolume::flush() {
  return {};
}

}  // namespace lucia::storage
