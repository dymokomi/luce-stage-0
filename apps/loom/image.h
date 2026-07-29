#pragma once

#include "fabric/persistence/store.h"
#include "storage/volume/file_volume.h"

namespace lucia {

enum { DEFAULT_PAGES = 64 };

// ---------------------------------------------------------------------------
// Image
// ---------------------------------------------------------------------------
//
// One Fabric opened from one image file for the duration of a command.
// Failures are reported on stderr so commands only branch on the result.
// The volume and store live and die together with the Image.
//
class Image {
public:
  Image();

  bool create(const char *path, U64 pages);
  bool open(const char *path);

  Store *store();

private:
  Image(const Image &);
  Image &operator=(const Image &);

  FileVolume volume;
  Store      fabric;
};

} // namespace lucia
