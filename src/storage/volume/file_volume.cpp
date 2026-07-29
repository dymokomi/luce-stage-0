#include "storage/volume/file_volume.h"

#include <limits.h>

namespace lucia {

FileVolume::FileVolume() : pages(0) {}

FileVolume::~FileVolume() {
  close();
}

bool FileVolume::is_open() const {
  return file.is_open();
}

bool FileVolume::contains(U64 page_index) const {
  return page_index < pages;
}

U64 FileVolume::byte_offset(U64 page_index) const {
  return page_index * (U64)PAGE_SIZE;
}

void FileVolume::close() {
  if (is_open()) {
    file.close();
  }
  pages = 0;
}

bool FileVolume::create(const char *path, U64 image_pages) {
  if (path == 0 || image_pages == 0 || image_pages > (U64)INT64_MAX / (U64)PAGE_SIZE) {
    return false;
  }

  close();

  const U64 image_bytes = image_pages * (U64)PAGE_SIZE;
  if (!file.create(path, image_bytes)) {
    return false;
  }

  pages = image_pages;
  return true;
}

bool FileVolume::open(const char *path) {
  if (path == 0) {
    return false;
  }

  close();

  if (!file.open(path)) {
    return false;
  }

  U64 image_bytes = 0;
  if (!file.size(&image_bytes) || image_bytes == 0 || (image_bytes % PAGE_SIZE) != 0 ||
      image_bytes / PAGE_SIZE > (U64)INT64_MAX / (U64)PAGE_SIZE) {
    close();
    return false;
  }

  pages = image_bytes / PAGE_SIZE;
  return true;
}

U64 FileVolume::size() const {
  return pages;
}

bool FileVolume::read(U64 page_index, void *destination) {
  if (!is_open() || destination == 0 || !contains(page_index)) {
    return false;
  }

  return file.read(byte_offset(page_index), destination, PAGE_SIZE);
}

bool FileVolume::write(U64 page_index, const void *source) {
  if (!is_open() || source == 0 || !contains(page_index)) {
    return false;
  }

  return file.write(byte_offset(page_index), source, PAGE_SIZE);
}

bool FileVolume::flush() {
  if (!is_open()) {
    return false;
  }
  return file.flush();
}

} // namespace lucia
