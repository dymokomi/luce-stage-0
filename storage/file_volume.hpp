#pragma once

#include <filesystem>

#include "volume.hpp"

namespace lucia::storage {

/// Page store backed by a host file (e.g. lucia.img).
class FileVolume final : public Volume {
 public:
  static Result<FileVolume> create(const std::filesystem::path& path,
                                   std::uint64_t page_count);
  static Result<FileVolume> open(const std::filesystem::path& path);

  FileVolume(FileVolume&& other) noexcept;
  FileVolume& operator=(FileVolume&& other) noexcept;
  ~FileVolume() override;

  Geometry geometry() const override;
  Result<void> read(std::uint64_t page, std::span<std::byte> out) override;
  Result<void> write(std::uint64_t page,
                     std::span<const std::byte> in) override;
  Result<void> flush() override;

 private:
  FileVolume(std::filesystem::path path, int fd, Geometry geo);

  Result<void> check(std::uint64_t page, std::size_t size) const;
  void close() noexcept;

  std::filesystem::path path_;
  int fd_ = -1;
  Geometry geo_{};
};

}  // namespace lucia::storage
