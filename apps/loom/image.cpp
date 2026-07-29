#include "image.h"

#include <stdio.h>

namespace lucia {

Image::Image() : handle(0) {}

Image::~Image() {
    if (handle != 0) {
        loom_store_close(handle);
    }
}

bool Image::create(const char *path, U64 pages) {
    if (loom_store_create(path, pages, &handle) != LOOM_OK) {
        handle = 0;
        fprintf(stderr, "loom: cannot create image %s\n", path);
        return false;
    }
    return true;
}

bool Image::open(const char *path) {
    if (loom_store_open(path, &handle) != LOOM_OK) {
        handle = 0;
        fprintf(stderr, "loom: cannot open image %s\n", path);
        return false;
    }
    return true;
}

loom_store *Image::store() {
    return handle;
}

} // namespace lucia
