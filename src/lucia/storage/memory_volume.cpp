#include "lucia/storage/memory_volume.hpp"

#include <cstring>

namespace lucia::storage {

MemoryVolume::MemoryVolume(std::uint64_t page_count, std::uint32_t page_size) {
  geometry_.page_size = page_size;
  geometry_.page_count = page_count;
  geometry_.required_alignment = 1;
  geometry_.max_transfer_size = page_size;
  geometry_.atomic_write_size = page_size;
  geometry_.flush_supported = true;

  const auto bytes = static_cast<std::size_t>(page_count) * page_size;
  data_.assign(bytes, std::byte{0});
}

Geometry MemoryVolume::geometry() const noexcept {
  return geometry_;
}

Status MemoryVolume::check_page(PageId page, std::size_t byte_count) const {
  if (byte_count != geometry_.page_size) {
    return std::unexpected(Error::WrongSize);
  }
  if (to_u64(page) >= geometry_.page_count) {
    return std::unexpected(Error::OutOfRange);
  }
  return {};
}

Status MemoryVolume::read(PageId page, MutableBytes destination) {
  if (auto status = check_page(page, destination.size()); !status) {
    return status;
  }

  const auto offset =
      static_cast<std::size_t>(to_u64(page)) * geometry_.page_size;
  std::memcpy(destination.data(), data_.data() + offset, destination.size());
  return {};
}

Status MemoryVolume::write(PageId page, Bytes source) {
  if (auto status = check_page(page, source.size()); !status) {
    return status;
  }

  const auto offset =
      static_cast<std::size_t>(to_u64(page)) * geometry_.page_size;
  std::memcpy(data_.data() + offset, source.data(), source.size());
  return {};
}

Status MemoryVolume::flush() {
  return {};
}

Bytes MemoryVolume::image() const noexcept {
  return Bytes{data_.data(), data_.size()};
}

}  // namespace lucia::storage
