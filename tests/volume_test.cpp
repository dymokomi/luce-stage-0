#include <stdio.h>
#include <string.h>

#include "file_volume.h"
#include "memory_volume.h"

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

static void zero_page(Byte* page)
{
  memset(page, 0, PAGE_SIZE);
}

static void test_memory_volume_basics()
{
  MemoryVolume volume(8);

  Byte page_a[PAGE_SIZE];
  Byte page_b[PAGE_SIZE];
  Byte page_got[PAGE_SIZE];

  fill_page(page_a, 0x10);
  fill_page(page_b, 0x20);

  CHECK(volume.size() == 8);
  CHECK(volume.write(0, page_a));
  CHECK(volume.write(7, page_b));
  CHECK(volume.flush());

  CHECK(volume.read(0, page_got));
  CHECK(memcmp(page_got, page_a, PAGE_SIZE) == 0);

  CHECK(volume.read(7, page_got));
  CHECK(memcmp(page_got, page_b, PAGE_SIZE) == 0);
}

static void test_memory_volume_bounds_and_nulls()
{
  MemoryVolume volume(4);
  Byte         page[PAGE_SIZE];
  Byte         page_got[PAGE_SIZE];

  fill_page(page, 0x40);

  CHECK(!volume.read(4, page_got));
  CHECK(!volume.write(4, page));
  CHECK(!volume.read(100, page_got));
  CHECK(!volume.write(100, page));

  CHECK(!volume.read(0, 0));
  CHECK(!volume.write(0, 0));
}

static void test_memory_volume_overwrite_and_zeros()
{
  MemoryVolume volume(2);
  Byte         page_a[PAGE_SIZE];
  Byte         page_b[PAGE_SIZE];
  Byte         page_got[PAGE_SIZE];
  Byte         zeros[PAGE_SIZE];

  fill_page(page_a, 0x11);
  fill_page(page_b, 0x22);
  zero_page(zeros);

  CHECK(volume.read(0, page_got));
  CHECK(memcmp(page_got, zeros, PAGE_SIZE) == 0);

  CHECK(volume.write(1, page_a));
  CHECK(volume.write(1, page_b));
  CHECK(volume.read(1, page_got));
  CHECK(memcmp(page_got, page_b, PAGE_SIZE) == 0);
  CHECK(memcmp(page_got, page_a, PAGE_SIZE) != 0);
}

static void test_memory_volume_all_pages()
{
  const U64 page_count = 5;
  MemoryVolume volume(page_count);

  Byte page[PAGE_SIZE];
  Byte page_got[PAGE_SIZE];

  for (U64 i = 0; i < page_count; ++i) {
    fill_page(page, static_cast<Byte>(0x50 + i));
    CHECK(volume.write(i, page));
  }
  CHECK(volume.flush());

  for (U64 i = 0; i < page_count; ++i) {
    fill_page(page, static_cast<Byte>(0x50 + i));
    CHECK(volume.read(i, page_got));
    CHECK(memcmp(page_got, page, PAGE_SIZE) == 0);
  }
}

static void test_file_volume_create_open_persist()
{
  const char* image_path = "/tmp/lucia-volume-test.img";
  Byte        page[PAGE_SIZE];
  Byte        page_got[PAGE_SIZE];

  fill_page(page, 0x33);
  remove(image_path);

  {
    FileVolume volume;
    CHECK(volume.create(image_path, 16));
    CHECK(volume.size() == 16);
    CHECK(volume.write(3, page));
    CHECK(volume.write(15, page));
    CHECK(volume.flush());
  }

  {
    FileVolume volume;
    CHECK(volume.open(image_path));
    CHECK(volume.size() == 16);
    CHECK(volume.read(3, page_got));
    CHECK(memcmp(page_got, page, PAGE_SIZE) == 0);
    CHECK(volume.read(15, page_got));
    CHECK(memcmp(page_got, page, PAGE_SIZE) == 0);
  }

  remove(image_path);
}

static void test_file_volume_bounds_and_nulls()
{
  const char* image_path = "/tmp/lucia-volume-bounds.img";
  Byte        page[PAGE_SIZE];
  Byte        page_got[PAGE_SIZE];

  fill_page(page, 0x44);
  remove(image_path);

  FileVolume volume;
  CHECK(volume.create(image_path, 4));

  CHECK(!volume.read(4, page_got));
  CHECK(!volume.write(4, page));
  CHECK(!volume.read(0, 0));
  CHECK(!volume.write(0, 0));

  volume.close();
  CHECK(volume.size() == 0);
  CHECK(!volume.read(0, page_got));
  CHECK(!volume.write(0, page));
  CHECK(!volume.flush());

  // close_image is safe to call more than once
  volume.close();

  remove(image_path);
}

static void test_file_volume_create_rejects_bad_args()
{
  FileVolume volume;

  CHECK(!volume.create(0, 8));
  CHECK(!volume.create("/tmp/lucia-volume-bad.img", 0));
  CHECK(!volume.open(0));
  CHECK(!volume.open("/tmp/lucia-volume-does-not-exist.img"));
}

static void test_file_volume_recreate_truncates()
{
  const char* image_path = "/tmp/lucia-volume-recreate.img";
  Byte        page_old[PAGE_SIZE];
  Byte        page_new[PAGE_SIZE];
  Byte        page_got[PAGE_SIZE];
  Byte        zeros[PAGE_SIZE];

  fill_page(page_old, 0x55);
  fill_page(page_new, 0x66);
  zero_page(zeros);
  remove(image_path);

  {
    FileVolume volume;
    CHECK(volume.create(image_path, 8));
    CHECK(volume.write(2, page_old));
    CHECK(volume.flush());
  }

  {
    FileVolume volume;
    CHECK(volume.create(image_path, 4));
    CHECK(volume.size() == 4);
    CHECK(volume.read(2, page_got));
    CHECK(memcmp(page_got, zeros, PAGE_SIZE) == 0);
    CHECK(volume.write(1, page_new));
    CHECK(volume.flush());
  }

  {
    FileVolume volume;
    CHECK(volume.open(image_path));
    CHECK(volume.size() == 4);
    CHECK(volume.read(1, page_got));
    CHECK(memcmp(page_got, page_new, PAGE_SIZE) == 0);
    CHECK(!volume.read(7, page_got));
  }

  remove(image_path);
}

static void test_file_volume_overwrite_after_open()
{
  const char* image_path = "/tmp/lucia-volume-overwrite.img";
  Byte        page_a[PAGE_SIZE];
  Byte        page_b[PAGE_SIZE];
  Byte        page_got[PAGE_SIZE];

  fill_page(page_a, 0x70);
  fill_page(page_b, 0x80);
  remove(image_path);

  {
    FileVolume volume;
    CHECK(volume.create(image_path, 8));
    CHECK(volume.write(0, page_a));
    CHECK(volume.flush());
  }

  {
    FileVolume volume;
    CHECK(volume.open(image_path));
    CHECK(volume.write(0, page_b));
    CHECK(volume.flush());
  }

  {
    FileVolume volume;
    CHECK(volume.open(image_path));
    CHECK(volume.read(0, page_got));
    CHECK(memcmp(page_got, page_b, PAGE_SIZE) == 0);
  }

  remove(image_path);
}

int main()
{
  test_memory_volume_basics();
  test_memory_volume_bounds_and_nulls();
  test_memory_volume_overwrite_and_zeros();
  test_memory_volume_all_pages();

  test_file_volume_create_open_persist();
  test_file_volume_bounds_and_nulls();
  test_file_volume_create_rejects_bad_args();
  test_file_volume_recreate_truncates();
  test_file_volume_overwrite_after_open();

  if (failures != 0) {
    fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }

  printf("ok\n");
  return 0;
}
