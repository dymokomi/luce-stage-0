#include "image.h"

#include <stdio.h>

namespace lucia {

const char DEFAULT_IMAGE[] = "loom.img";

Image::Image() {}

bool Image::create(const char *path, U64 pages) {
  if (!volume.create(path, pages)) {
    fprintf(stderr, "loom: cannot create image %s\n", path);
    return false;
  }
  if (!fabric.create(&volume)) {
    fprintf(stderr, "loom: cannot initialize Fabric\n");
    return false;
  }
  return true;
}

bool Image::open(const char *path) {
  if (!volume.open(path)) {
    fprintf(stderr, "loom: cannot open image %s\n", path);
    return false;
  }
  if (!fabric.open(&volume)) {
    fprintf(stderr, "loom: cannot open Fabric %s\n", path);
    return false;
  }
  return true;
}

Store *Image::store() {
  return &fabric;
}

} // namespace lucia
