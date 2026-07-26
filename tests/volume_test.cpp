#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "file_volume.hpp"
#include "memory_volume.hpp"

using namespace lucia;

static int failures = 0;

#define CHECK(cond)                                                          \
  do {                                                                       \
    if (!(cond)) {                                                           \
      fprintf(stderr, "fail: %s (%s:%d)\n", #cond, __FILE__, __LINE__);      \
      ++failures;                                                            \
    }                                                                        \
  } while (0)

static void fill(unsigned char* page, unsigned char seed) {
  for (int i = 0; i < PAGE_SIZE; ++i) {
    page[i] = static_cast<unsigned char>(seed + i);
  }
}

static void test_memory() {
  MemoryVolume vol(8);
  unsigned char a[PAGE_SIZE];
  unsigned char b[PAGE_SIZE];
  unsigned char got[PAGE_SIZE];

  fill(a, 0x10);
  fill(b, 0x20);

  CHECK(vol.pages() == 8);
  CHECK(vol.write(0, a));
  CHECK(vol.write(7, b));
  CHECK(vol.flush());
  CHECK(vol.read(0, got) && memcmp(got, a, PAGE_SIZE) == 0);
  CHECK(vol.read(7, got) && memcmp(got, b, PAGE_SIZE) == 0);
  CHECK(!vol.read(8, got));
  CHECK(!vol.write(8, a));
}

static void test_file() {
  const char* path = "/tmp/lucia-test.img";
  unsigned char page[PAGE_SIZE];
  unsigned char got[PAGE_SIZE];
  fill(page, 0x33);

  {
    FileVolume vol;
    CHECK(vol.create(path, 16));
    CHECK(vol.write(3, page));
    CHECK(vol.flush());
  }

  {
    FileVolume vol;
    CHECK(vol.open(path));
    CHECK(vol.pages() == 16);
    CHECK(vol.read(3, got) && memcmp(got, page, PAGE_SIZE) == 0);
  }

  remove(path);
}

int main() {
  test_memory();
  test_file();

  if (failures) {
    fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  printf("ok\n");
  return 0;
}
