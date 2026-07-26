#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <vector>

#include "file_volume.hpp"
#include "memory_volume.hpp"

namespace {

using namespace lucia::storage;

int failures = 0;

#define CHECK(cond)                                                          \
  do {                                                                       \
    if (!(cond)) {                                                           \
      std::cerr << "fail: " << #cond << " @" << __LINE__ << "\n";            \
      ++failures;                                                            \
    }                                                                        \
  } while (0)

std::vector<std::byte> pattern(std::uint8_t seed) {
  std::vector<std::byte> page(kPageSize);
  for (std::size_t i = 0; i < page.size(); ++i) {
    page[i] = static_cast<std::byte>(seed + static_cast<std::uint8_t>(i));
  }
  return page;
}

void check_page(Volume& vol, std::uint64_t page,
                const std::vector<std::byte>& want) {
  std::vector<std::byte> got(kPageSize);
  CHECK(vol.read(page, got).has_value());
  CHECK(got == want);
}

void test_memory() {
  MemoryVolume vol(8);
  CHECK(vol.geometry().page_count == 8);
  CHECK(vol.geometry().page_size == kPageSize);

  const auto a = pattern(0x10);
  const auto b = pattern(0x20);
  CHECK(vol.write(0, a).has_value());
  CHECK(vol.write(7, b).has_value());
  CHECK(vol.flush().has_value());
  check_page(vol, 0, a);
  check_page(vol, 7, b);

  std::vector<std::byte> page(kPageSize);
  std::vector<std::byte> short_buf(kPageSize - 1);
  CHECK(vol.read(8, page).error() == Error::OutOfRange);
  CHECK(vol.write(0, short_buf).error() == Error::WrongSize);
}

void test_file() {
  const auto path =
      std::filesystem::temp_directory_path() / "lucia-test.img";
  std::filesystem::remove(path);

  const auto page = pattern(0x33);
  {
    auto vol = FileVolume::create(path, 16);
    CHECK(vol.has_value());
    CHECK(vol->write(3, page).has_value());
    CHECK(vol->flush().has_value());
  }
  {
    auto vol = FileVolume::open(path);
    CHECK(vol.has_value());
    CHECK(vol->geometry().page_count == 16);
    check_page(*vol, 3, page);
  }

  std::filesystem::remove(path);
}

}  // namespace

int main() {
  test_memory();
  test_file();

  if (failures != 0) {
    std::cerr << failures << " failure(s)\n";
    return EXIT_FAILURE;
  }
  std::cout << "ok\n";
  return EXIT_SUCCESS;
}
