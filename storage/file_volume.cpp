#include "file_volume.hpp"

#include <fcntl.h>
#include <unistd.h>

namespace lucia {

FileVolume::FileVolume() : fd_(-1), pages_(0) {}

FileVolume::~FileVolume() {
  close();
}

void FileVolume::close() {
  if (fd_ >= 0) {
    ::close(fd_);
    fd_ = -1;
  }
  pages_ = 0;
}

bool FileVolume::create(const char* path, uint64_t page_count) {
  if (!path || page_count == 0) {
    return false;
  }

  close();

  fd_ = ::open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  if (fd_ < 0) {
    return false;
  }

  off_t bytes = static_cast<off_t>(page_count) * PAGE_SIZE;
  if (ftruncate(fd_, bytes) != 0) {
    close();
    return false;
  }

  pages_ = page_count;
  return true;
}

bool FileVolume::open(const char* path) {
  if (!path) {
    return false;
  }

  close();

  fd_ = ::open(path, O_RDWR | O_CLOEXEC);
  if (fd_ < 0) {
    return false;
  }

  off_t end = lseek(fd_, 0, SEEK_END);
  if (end <= 0 || (end % PAGE_SIZE) != 0 || lseek(fd_, 0, SEEK_SET) < 0) {
    close();
    return false;
  }

  pages_ = static_cast<uint64_t>(end) / PAGE_SIZE;
  return true;
}

uint64_t FileVolume::pages() const {
  return pages_;
}

bool FileVolume::read(uint64_t page, void* buf) {
  if (fd_ < 0 || !buf || page >= pages_) {
    return false;
  }

  off_t off = static_cast<off_t>(page) * PAGE_SIZE;
  ssize_t n = pread(fd_, buf, PAGE_SIZE, off);
  return n == PAGE_SIZE;
}

bool FileVolume::write(uint64_t page, const void* buf) {
  if (fd_ < 0 || !buf || page >= pages_) {
    return false;
  }

  off_t off = static_cast<off_t>(page) * PAGE_SIZE;
  ssize_t n = pwrite(fd_, buf, PAGE_SIZE, off);
  return n == PAGE_SIZE;
}

bool FileVolume::flush() {
  if (fd_ < 0) {
    return false;
  }
  return fsync(fd_) == 0;
}

}  // namespace lucia
