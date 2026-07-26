#pragma once

#include <vector>

#include "lucia/storage/volume.hpp"

namespace lucia::storage {

/// In-process page store for fast tests.
/// flush() is a no-op durability barrier: memory is already "durable"
/// for the lifetime of the process.
class MemoryVolume final : public Volume {
 public:
  explicit MemoryVolume(std::uint64_t page_count,
                        std::uint32_t page_size = kDefaultPageSize);

  [[nodiscard]] Geometry geometry() const noexcept override;
  [[nodiscard]] Status read(PageId page, MutableBytes destination) override;
  [[nodiscard]] Status write(PageId page, Bytes source) override;
  [[nodiscard]] Status flush() override;

  /// Expose raw image bytes for crash/corruption tests.
  [[nodiscard]] Bytes image() const noexcept;

 private:
  [[nodiscard]] Status check_page(PageId page, std::size_t byte_count) const;

  Geometry geometry_{};
  ByteBuffer data_;
};

}  // namespace lucia::storage
