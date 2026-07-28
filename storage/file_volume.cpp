#include "file_volume.h"

#include <fcntl.h>
#include <unistd.h>

namespace lucia {

FileVolume::FileVolume()
    : file_handle(-1),
      pages(0)
{
}

FileVolume::~FileVolume()
{
  close();
}

bool FileVolume::is_open() const
{
  return file_handle >= 0;
}

bool FileVolume::contains(U64 page_index) const
{
  return page_index < pages;
}

S64 FileVolume::byte_offset(U64 page_index) const
{
  return static_cast<S64>(page_index) * PAGE_SIZE;
}

void FileVolume::close()
{
  if (is_open()) {
    ::close(file_handle);
    file_handle = -1;
  }
  pages = 0;
}

bool FileVolume::create(const char* path, U64 pages)
{
  if (path == 0 || pages == 0) {
    return false;
  }

  close();

  file_handle = ::open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  if (!is_open()) {
    return false;
  }

  const S64 image_bytes = static_cast<S64>(pages) * PAGE_SIZE;
  if (ftruncate(file_handle, image_bytes) != 0) {
    close();
    return false;
  }

  this->pages = pages;
  return true;
}

bool FileVolume::open(const char* path)
{
  if (path == 0) {
    return false;
  }

  close();

  file_handle = ::open(path, O_RDWR | O_CLOEXEC);
  if (!is_open()) {
    return false;
  }

  const S64 image_bytes = lseek(file_handle, 0, SEEK_END);
  if (image_bytes <= 0 ||
      (image_bytes % PAGE_SIZE) != 0 ||
      lseek(file_handle, 0, SEEK_SET) < 0) {
    close();
    return false;
  }

  pages = static_cast<U64>(image_bytes) / PAGE_SIZE;
  return true;
}

U64 FileVolume::size() const
{
  return pages;
}

bool FileVolume::read(U64 page_index, void* destination)
{
  if (!is_open() || destination == 0 || !contains(page_index)) {
    return false;
  }

  const S64 offset     = byte_offset(page_index);
  const S64 bytes_read = pread(file_handle, destination, PAGE_SIZE, offset);
  return bytes_read == PAGE_SIZE;
}

bool FileVolume::write(U64 page_index, const void* source)
{
  if (!is_open() || source == 0 || !contains(page_index)) {
    return false;
  }

  const S64 offset        = byte_offset(page_index);
  const S64 bytes_written = pwrite(file_handle, source, PAGE_SIZE, offset);
  return bytes_written == PAGE_SIZE;
}

bool FileVolume::flush()
{
  if (!is_open()) {
    return false;
  }
  return fsync(file_handle) == 0;
}

}  // namespace lucia
