#include <stdio.h>
#include <string.h>

#include "file_volume.hpp"
#include "memory_volume.hpp"

using namespace lucia;

static int g_failures = 0;

#define CHECK(condition)                                                     \
  do {                                                                       \
    if (!(condition)) {                                                      \
      fprintf(stderr, "fail: %s (%s:%d)\n", #condition, __FILE__, __LINE__); \
      ++g_failures;                                                          \
    }                                                                        \
  } while (0)

static void fill_page(unsigned char* page, unsigned char seed)
{
  for (int i = 0; i < PAGE_SIZE; ++i) {
    page[i] = static_cast<unsigned char>(seed + i);
  }
}

static void test_memory_volume()
{
  MemoryVolume volume(8);

  unsigned char page_a[PAGE_SIZE];
  unsigned char page_b[PAGE_SIZE];
  unsigned char page_got[PAGE_SIZE];

  fill_page(page_a, 0x10);
  fill_page(page_b, 0x20);

  CHECK(volume.page_count() == 8);
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
  const char*   image_path = "/tmp/lucia-test.img";
  unsigned char page[PAGE_SIZE];
  unsigned char page_got[PAGE_SIZE];

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
    CHECK(volume.page_count() == 16);
    CHECK(volume.read_page(3, page_got));
    CHECK(memcmp(page_got, page, PAGE_SIZE) == 0);
  }

  remove(image_path);
}

int main()
{
  test_memory_volume();
  test_file_volume();

  if (g_failures != 0) {
    fprintf(stderr, "%d failure(s)\n", g_failures);
    return 1;
  }

  printf("ok\n");
  return 0;
}
