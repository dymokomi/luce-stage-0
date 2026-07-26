#pragma once

#include <cstdint>
#include <filesystem>
#include <string>

#include "lucia/storage/volume.hpp"

namespace lucia::platform::posix {

/// Host-file backed volume (`lucia.img` style).
///
/// macOS/Linux store opaque bytes; Lucia owns the page layout inside.
/// flush() uses fsync so callers can establish durability barriers.
class FileVolume final : public lucia::storage::Volume {
 public:
  /// Create a new zero-filled image file and open it.
  [[nodiscard]] static lucia::storage::Result<FileVolume> create(
      const std::filesystem::path& path,
      std::uint64_t page_count,
      std::uint32_t page_size = lucia::storage::kDefaultPageSize);

  /// Open an existing image. Size must be a multiple of page_size.
  [[nodiscard]] static lucia::storage::Result<FileVolume> open(
      const std::filesystem::path& path,
      std::uint32_t page_size = lucia::storage::kDefaultPageSize);

  FileVolume(FileVolume&& other) noexcept;
  FileVolume& operator=(FileVolume&& other) noexcept;
  ~FileVolume() override;

  [[nodiscard]] lucia::storage::Geometry geometry() const noexcept override;
  [[nodiscard]] lucia::storage::Status read(
      lucia::storage::PageId page,
      lucia::storage::MutableBytes destination) override;
  [[nodiscard]] lucia::storage::Status write(
      lucia::storage::PageId page,
      lucia::storage::Bytes source) override;
  [[nodiscard]] lucia::storage::Status flush() override;

  [[nodiscard]] const std::filesystem::path& path() const noexcept;

 private:
  FileVolume(std::filesystem::path path,
             int fd,
             lucia::storage::Geometry geometry) noexcept;

  [[nodiscard]] lucia::storage::Status check_page(
      lucia::storage::PageId page,
      std::size_t byte_count) const;
  void close_fd() noexcept;

  std::filesystem::path path_;
  int fd_ = -1;
  lucia::storage::Geometry geometry_{};
};

}  // namespace lucia::platform::posix
