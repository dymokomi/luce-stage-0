#pragma once

#include "volume.hpp"

namespace lucia {

// Page store backed by a host file (lucia.img).
class FileVolume : public Volume {
public:
  FileVolume();
  ~FileVolume();

  bool create(const char* path, uint64_t page_count);
  bool open(const char* path);
  void close();

  uint64_t pages() const;
  bool read(uint64_t page, void* buf);
  bool write(uint64_t page, const void* buf);
  bool flush();

private:
  FileVolume(const FileVolume&);
  FileVolume& operator=(const FileVolume&);

  int fd_;
  uint64_t pages_;
};

}  // namespace lucia
