#include <stdio.h>
#include <string.h>

#include "file_volume.hpp"
#include "memory_volume.hpp"

using namespace lucia;

static int failures = 0;

#define CHECK(condition)                                                     \
  do {                                                                       \
    if (!(condition)) {                                                      \
      fprintf(stderr, "fail: %s (%s:%d)\n", #condition, __FILE__, __LINE__); \
      ++failures;                                                            \
    }                                                                        \
  } while (0)

static void fill_page(Byte* page, Byte seed)
{
  for (int i = 0; i < PAGE_SIZE; ++i) {
    page[i] = static_cast<Byte>(seed + i);
  }
}

static void test_memory_volume()
{
  MemoryVolume volume(8);

  Byte page_a[PAGE_SIZE];
  Byte page_b[PAGE_SIZE];
  Byte page_got[PAGE_SIZE];

  fill_page(page_a, 0x10);
  fill_page(page_b, 0x20);

  CHECK(volume.count_pages() == 8);
  CHECK(volume.write_page(0, page_a));
  CHECK(volume.write_page(7, page_b));
  CHECK(volume.flush_writes());

  CHECK(volume.read_page(0, page_got));
  CHECK(memcmp(page_got, page_a, PAGE_SIZE) == 0);

  CHECK(volume.read_page(7, page_got));
  CHECK(memcmp(page_got, page_b, PAGE_SIZE) == 0);

  CHECK(!volume.read_page(8, page_got));
  CHECK(!volume.write_page(8, page_a));
}

static void test_file_volume()
{
  const char* image_path = "/tmp/lucia-test.img";
  Byte        page[PAGE_SIZE];
  Byte        page_got[PAGE_SIZE];

  fill_page(page, 0x33);

  {
    FileVolume volume;
    CHECK(volume.create_image(image_path, 16));
    CHECK(volume.write_page(3, page));
    CHECK(volume.flush_writes());
  }

  {
    FileVolume volume;
    CHECK(volume.open_image(image_path));
    CHECK(volume.count_pages() == 16);
    CHECK(volume.read_page(3, page_got));
    CHECK(memcmp(page_got, page, PAGE_SIZE) == 0);
  }

  remove(image_path);
}

int main()
{
  test_memory_volume();
  test_file_volume();

  if (failures != 0) {
    fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }

  printf("ok\n");
  return 0;
}
