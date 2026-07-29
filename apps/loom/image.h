#pragma once

#include "engine.h"

namespace lucia {

enum { DEFAULT_PAGES = 64 };

// ---------------------------------------------------------------------------
// Image
// ---------------------------------------------------------------------------
//
// One Fabric opened from one image file for the duration of a command,
// through the engine's C border.  Failures are reported on stderr so
// callers only branch on the result.
//
class Image {
public:
    Image();
    ~Image();

    bool create(const char *path, U64 pages);
    bool open(const char *path);

    loom_store *store();

private:
    Image(const Image &);
    Image &operator=(const Image &);

    loom_store *handle;
};

} // namespace lucia
