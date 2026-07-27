#pragma once

#include "volume.h"

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
  bool create_image(const char* path, U64 pages);

  // Open an existing image.  File size must be a multiple of PAGE_SIZE.
  bool open_image(const char* path);

  // Release the host file.  Safe to call more than once.
  void close_image();

  U64 count_pages() const override;

  bool read_page (U64 page_index, void*       destination) override;
  bool write_page(U64 page_index, const void* source)      override;
  bool flush_writes() override;

private:
  FileVolume(const FileVolume&);             // not copyable
  FileVolume& operator=(const FileVolume&);  // not copyable

  bool is_open() const;
  bool contains_page(U64 page_index) const;
  S64  byte_offset_for_page(U64 page_index) const;

  int file_handle;
  U64 pages;
};

}  // namespace lucia
