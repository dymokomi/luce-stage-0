#include "lucia/platform/posix/file_volume.hpp"

#include <fcntl.h>
#include <unistd.h>

#include <utility>

namespace lucia::platform::posix {
namespace {

using lucia::storage::Error;
using lucia::storage::Geometry;
using lucia::storage::Result;
using lucia::storage::Status;
using lucia::storage::to_u64;

[[nodiscard]] Status posix_io_status(ssize_t n, std::size_t expected) {
  if (n < 0) {
    return std::unexpected(Error::IoFailure);
  }
  if (static_cast<std::size_t>(n) != expected) {
    return std::unexpected(Error::IoFailure);
  }
  return {};
}

}  // namespace

FileVolume::FileVolume(std::filesystem::path path,
                       int fd,
                       Geometry geometry) noexcept
    : path_(std::move(path)), fd_(fd), geometry_(geometry) {}

FileVolume::FileVolume(FileVolume&& other) noexcept
    : path_(std::move(other.path_)),
      fd_(std::exchange(other.fd_, -1)),
      geometry_(other.geometry_) {}

FileVolume& FileVolume::operator=(FileVolume&& other) noexcept {
  if (this != &other) {
    close_fd();
    path_ = std::move(other.path_);
    fd_ = std::exchange(other.fd_, -1);
    geometry_ = other.geometry_;
  }
  return *this;
}

FileVolume::~FileVolume() {
  close_fd();
}

void FileVolume::close_fd() noexcept {
  if (fd_ >= 0) {
    ::close(fd_);
    fd_ = -1;
  }
}

Result<FileVolume> FileVolume::create(const std::filesystem::path& path,
                                      std::uint64_t page_count,
                                      std::uint32_t page_size) {
  if (page_size == 0 || page_count == 0) {
    return std::unexpected(Error::WrongSize);
  }

  const int fd = ::open(path.c_str(),
                        O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC,
                        0600);
  if (fd < 0) {
    return std::unexpected(Error::IoFailure);
  }

  const auto bytes =
      static_cast<off_t>(page_count) * static_cast<off_t>(page_size);
  if (::ftruncate(fd, bytes) != 0) {
    ::close(fd);
    return std::unexpected(Error::IoFailure);
  }

  Geometry geometry{
      .page_size = page_size,
      .page_count = page_count,
      .required_alignment = 1,
      .max_transfer_size = page_size,
      .atomic_write_size = 0,
      .flush_supported = true,
  };

  return FileVolume{path, fd, geometry};
}

Result<FileVolume> FileVolume::open(const std::filesystem::path& path,
                                    std::uint32_t page_size) {
  if (page_size == 0) {
    return std::unexpected(Error::WrongSize);
  }

  const int fd = ::open(path.c_str(), O_RDWR | O_CLOEXEC);
  if (fd < 0) {
    return std::unexpected(Error::IoFailure);
  }

  const off_t end = ::lseek(fd, 0, SEEK_END);
  if (end < 0) {
    ::close(fd);
    return std::unexpected(Error::IoFailure);
  }
  if (::lseek(fd, 0, SEEK_SET) < 0) {
    ::close(fd);
    return std::unexpected(Error::IoFailure);
  }

  if (end == 0 || (static_cast<std::uint64_t>(end) % page_size) != 0) {
    ::close(fd);
    return std::unexpected(Error::WrongSize);
  }

  Geometry geometry{
      .page_size = page_size,
      .page_count = static_cast<std::uint64_t>(end) / page_size,
      .required_alignment = 1,
      .max_transfer_size = page_size,
      .atomic_write_size = 0,
      .flush_supported = true,
  };

  return FileVolume{path, fd, geometry};
}

Geometry FileVolume::geometry() const noexcept {
  return geometry_;
}

const std::filesystem::path& FileVolume::path() const noexcept {
  return path_;
}

Status FileVolume::check_page(lucia::storage::PageId page,
                              std::size_t byte_count) const {
  if (fd_ < 0) {
    return std::unexpected(Error::Closed);
  }
  if (byte_count != geometry_.page_size) {
    return std::unexpected(Error::WrongSize);
  }
  if (to_u64(page) >= geometry_.page_count) {
    return std::unexpected(Error::OutOfRange);
  }
  return {};
}

Status FileVolume::read(lucia::storage::PageId page,
                        lucia::storage::MutableBytes destination) {
  if (auto status = check_page(page, destination.size()); !status) {
    return status;
  }

  const auto offset =
      static_cast<off_t>(to_u64(page)) *
      static_cast<off_t>(geometry_.page_size);
  const ssize_t n =
      ::pread(fd_, destination.data(), destination.size(), offset);
  return posix_io_status(n, destination.size());
}

Status FileVolume::write(lucia::storage::PageId page,
                         lucia::storage::Bytes source) {
  if (auto status = check_page(page, source.size()); !status) {
    return status;
  }

  const auto offset =
      static_cast<off_t>(to_u64(page)) *
      static_cast<off_t>(geometry_.page_size);
  const ssize_t n = ::pwrite(fd_, source.data(), source.size(), offset);
  return posix_io_status(n, source.size());
}

Status FileVolume::flush() {
  if (fd_ < 0) {
    return std::unexpected(Error::Closed);
  }
  if (::fsync(fd_) != 0) {
    return std::unexpected(Error::FlushFailure);
  }
  return {};
}

}  // namespace lucia::platform::posix
