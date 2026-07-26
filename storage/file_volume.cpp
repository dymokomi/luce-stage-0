#include "file_volume.hpp"

#include <fcntl.h>
#include <unistd.h>

#include <utility>

namespace lucia::storage {
namespace {

Result<void> check_io(ssize_t n, std::size_t expected) {
  if (n < 0 || static_cast<std::size_t>(n) != expected) {
    return std::unexpected(Error::Io);
  }
  return {};
}

}  // namespace

FileVolume::FileVolume(std::filesystem::path path, int fd, Geometry geo)
    : path_(std::move(path)), fd_(fd), geo_(geo) {}

FileVolume::FileVolume(FileVolume&& other) noexcept
    : path_(std::move(other.path_)),
      fd_(std::exchange(other.fd_, -1)),
      geo_(other.geo_) {}

FileVolume& FileVolume::operator=(FileVolume&& other) noexcept {
  if (this != &other) {
    close();
    path_ = std::move(other.path_);
    fd_ = std::exchange(other.fd_, -1);
    geo_ = other.geo_;
  }
  return *this;
}

FileVolume::~FileVolume() {
  close();
}

void FileVolume::close() noexcept {
  if (fd_ >= 0) {
    ::close(fd_);
    fd_ = -1;
  }
}

Result<FileVolume> FileVolume::create(const std::filesystem::path& path,
                                      std::uint64_t page_count) {
  if (page_count == 0) {
    return std::unexpected(Error::WrongSize);
  }

  const int fd =
      ::open(path.c_str(), O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  if (fd < 0) {
    return std::unexpected(Error::Io);
  }

  const off_t bytes = static_cast<off_t>(page_count) * kPageSize;
  if (::ftruncate(fd, bytes) != 0) {
    ::close(fd);
    return std::unexpected(Error::Io);
  }

  return FileVolume{path, fd, Geometry{.page_count = page_count}};
}

Result<FileVolume> FileVolume::open(const std::filesystem::path& path) {
  const int fd = ::open(path.c_str(), O_RDWR | O_CLOEXEC);
  if (fd < 0) {
    return std::unexpected(Error::Io);
  }

  const off_t end = ::lseek(fd, 0, SEEK_END);
  if (end <= 0 || (end % kPageSize) != 0 || ::lseek(fd, 0, SEEK_SET) < 0) {
    ::close(fd);
    return std::unexpected(Error::Io);
  }

  const auto pages = static_cast<std::uint64_t>(end) / kPageSize;
  return FileVolume{path, fd, Geometry{.page_count = pages}};
}

Geometry FileVolume::geometry() const {
  return geo_;
}

Result<void> FileVolume::check(std::uint64_t page, std::size_t size) const {
  if (fd_ < 0) {
    return std::unexpected(Error::Io);
  }
  if (size != kPageSize) {
    return std::unexpected(Error::WrongSize);
  }
  if (page >= geo_.page_count) {
    return std::unexpected(Error::OutOfRange);
  }
  return {};
}

Result<void> FileVolume::read(std::uint64_t page, std::span<std::byte> out) {
  if (auto s = check(page, out.size()); !s) {
    return s;
  }
  const off_t offset = static_cast<off_t>(page) * kPageSize;
  return check_io(::pread(fd_, out.data(), kPageSize, offset), kPageSize);
}

Result<void> FileVolume::write(std::uint64_t page,
                               std::span<const std::byte> in) {
  if (auto s = check(page, in.size()); !s) {
    return s;
  }
  const off_t offset = static_cast<off_t>(page) * kPageSize;
  return check_io(::pwrite(fd_, in.data(), kPageSize, offset), kPageSize);
}

Result<void> FileVolume::flush() {
  if (fd_ < 0) {
    return std::unexpected(Error::Io);
  }
  if (::fsync(fd_) != 0) {
    return std::unexpected(Error::Flush);
  }
  return {};
}

}  // namespace lucia::storage
