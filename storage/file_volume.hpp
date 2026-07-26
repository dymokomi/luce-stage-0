#pragma once

#include "volume.hpp"

namespace lucia {

// ---------------------------------------------------------------------------
// FileVolume
// ---------------------------------------------------------------------------
//
// Page store backed by one host file (for example lucia.img).
//
// Typical use:
//
//   FileVolume volume;
//   volume.create_image("lucia.img", 1024);
//   volume.write_page(0, header_bytes);
//   volume.flush_writes();
//
class FileVolume : public Volume {
public:
  FileVolume();
  ~FileVolume();

  // Open a brand-new zero-filled image, replacing any existing file.
  bool create_image(const char* path, uint64_t page_count);

  // Open an existing image.  File size must be a multiple of PAGE_SIZE.
  bool open_image(const char* path);

  // Release the host file.  Safe to call more than once.
  void close_image();

  uint64_t page_count() const override;

  bool read_page (uint64_t page_index, void*       destination) override;
  bool write_page(uint64_t page_index, const void* source)      override;
  bool flush_writes() override;

private:
  FileVolume(const FileVolume&);             // not copyable
  FileVolume& operator=(const FileVolume&);  // not copyable

  bool is_open() const;
  bool contains_page(uint64_t page_index) const;
  int64_t byte_offset_for_page(uint64_t page_index) const;

  int      file_handle_;
  uint64_t page_count_;
};

}  // namespace lucia
