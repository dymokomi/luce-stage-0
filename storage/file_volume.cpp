#include "file_volume.hpp"

#include <fcntl.h>
#include <unistd.h>

namespace lucia {

FileVolume::FileVolume()
    : file_handle_(-1),
      page_count_(0)
{
}

FileVolume::~FileVolume()
{
  close_image();
}

bool FileVolume::is_open() const
{
  return file_handle_ >= 0;
}

bool FileVolume::contains_page(uint64_t page_index) const
{
  return page_index < page_count_;
}

int64_t FileVolume::byte_offset_for_page(uint64_t page_index) const
{
  return static_cast<int64_t>(page_index) * PAGE_SIZE;
}

void FileVolume::close_image()
{
  if (is_open()) {
    ::close(file_handle_);
    file_handle_ = -1;
  }
  page_count_ = 0;
}

bool FileVolume::create_image(const char* path, uint64_t page_count)
{
  if (path == 0 || page_count == 0) {
    return false;
  }

  close_image();

  file_handle_ = ::open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  if (!is_open()) {
    return false;
  }

  const int64_t image_bytes = static_cast<int64_t>(page_count) * PAGE_SIZE;
  if (ftruncate(file_handle_, image_bytes) != 0) {
    close_image();
    return false;
  }

  page_count_ = page_count;
  return true;
}

bool FileVolume::open_image(const char* path)
{
  if (path == 0) {
    return false;
  }

  close_image();

  file_handle_ = ::open(path, O_RDWR | O_CLOEXEC);
  if (!is_open()) {
    return false;
  }

  const int64_t image_bytes = lseek(file_handle_, 0, SEEK_END);
  if (image_bytes <= 0 ||
      (image_bytes % PAGE_SIZE) != 0 ||
      lseek(file_handle_, 0, SEEK_SET) < 0) {
    close_image();
    return false;
  }

  page_count_ = static_cast<uint64_t>(image_bytes) / PAGE_SIZE;
  return true;
}

uint64_t FileVolume::page_count() const
{
  return page_count_;
}

bool FileVolume::read_page(uint64_t page_index, void* destination)
{
  if (!is_open() || destination == 0 || !contains_page(page_index)) {
    return false;
  }

  const int64_t byte_offset = byte_offset_for_page(page_index);
  const int64_t bytes_read  = pread(file_handle_, destination, PAGE_SIZE,
                                    byte_offset);
  return bytes_read == PAGE_SIZE;
}

bool FileVolume::write_page(uint64_t page_index, const void* source)
{
  if (!is_open() || source == 0 || !contains_page(page_index)) {
    return false;
  }

  const int64_t byte_offset   = byte_offset_for_page(page_index);
  const int64_t bytes_written = pwrite(file_handle_, source, PAGE_SIZE,
                                       byte_offset);
  return bytes_written == PAGE_SIZE;
}

bool FileVolume::flush_writes()
{
  if (!is_open()) {
    return false;
  }
  return fsync(file_handle_) == 0;
}

}  // namespace lucia
