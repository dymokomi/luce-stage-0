#pragma once

#include "platform/file.h"
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
//   volume.create("lucia.img", 1024);
//   volume.write(0, header_bytes);
//   volume.flush();
//
class FileVolume : public Volume {
public:
  FileVolume();
  ~FileVolume();

  // Open a brand-new zero-filled image, replacing any existing file.
  bool create(const char* path, U64 pages);

  // Open an existing image.  File size must be a multiple of PAGE_SIZE.
  bool open(const char* path);

  // Release the host file.  Safe to call more than once.
  void close();

  U64 size() const override;

  bool read (U64 page_index, void*       destination) override;
  bool write(U64 page_index, const void* source)      override;
  bool flush() override;

private:
  FileVolume(const FileVolume&);
  FileVolume& operator=(const FileVolume&);

  bool is_open() const;
  bool contains(U64 page_index) const;
  U64  byte_offset(U64 page_index) const;

  PlatformFile file;
  U64          pages;
};

}  // namespace lucia
