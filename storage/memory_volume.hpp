#pragma once

#include <vector>

#include "volume.hpp"

namespace lucia::storage {

class MemoryVolume final : public Volume {
 public:
  explicit MemoryVolume(std::uint64_t page_count);

  Geometry geometry() const override;
  Result<void> read(std::uint64_t page, std::span<std::byte> out) override;
  Result<void> write(std::uint64_t page,
                     std::span<const std::byte> in) override;
  Result<void> flush() override;

 private:
  Result<void> check(std::uint64_t page, std::size_t size) const;

  Geometry geo_{};
  std::vector<std::byte> data_;
};

}  // namespace lucia::storage
