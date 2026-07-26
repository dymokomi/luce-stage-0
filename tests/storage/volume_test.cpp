#include <cstdlib>
#include <filesystem>
#include <iostream>

#include "lucia/platform/posix/file_volume.hpp"
#include "lucia/storage/faulty_volume.hpp"
#include "lucia/storage/memory_volume.hpp"

namespace {

using lucia::platform::posix::FileVolume;
using lucia::storage::ByteBuffer;
using lucia::storage::Bytes;
using lucia::storage::Error;
using lucia::storage::FaultyVolume;
using lucia::storage::MemoryVolume;
using lucia::storage::MutableBytes;
using lucia::storage::PageId;
using lucia::storage::Volume;
using lucia::storage::kDefaultPageSize;
using lucia::storage::page_id;

int g_failures = 0;

#define CHECK(cond)                                                          \
  do {                                                                       \
    if (!(cond)) {                                                           \
      std::cerr << "CHECK failed: " << #cond << " (" << __FILE__ << ":"     \
                << __LINE__ << ")\n";                                        \
      ++g_failures;                                                          \
    }                                                                        \
  } while (0)

#define CHECK_EQ(a, b)                                                       \
  do {                                                                       \
    const auto _a = (a);                                                     \
    const auto _b = (b);                                                     \
    if (!(_a == _b)) {                                                       \
      std::cerr << "CHECK_EQ failed: " << #a << " == " << #b << " ("        \
                << __FILE__ << ":" << __LINE__ << ")\n";                     \
      ++g_failures;                                                          \
    }                                                                        \
  } while (0)

ByteBuffer make_page_pattern(std::uint64_t seed) {
  ByteBuffer page(kDefaultPageSize);
  for (std::size_t i = 0; i < page.size(); ++i) {
    page[i] = static_cast<std::byte>((seed + i) & 0xFF);
  }
  return page;
}

void expect_page_eq(Volume& volume, PageId id, const ByteBuffer& expected) {
  ByteBuffer got(kDefaultPageSize);
  const auto status = volume.read(id, MutableBytes{got});
  CHECK(status.has_value());
  CHECK(got == expected);
}

void test_memory_round_trip() {
  MemoryVolume volume(/*page_count=*/8);
  CHECK_EQ(volume.geometry().page_size, kDefaultPageSize);
  CHECK_EQ(volume.geometry().page_count, 8u);

  const auto page0 = make_page_pattern(0x10);
  const auto page7 = make_page_pattern(0x77);
  CHECK(volume.write(page_id(0), Bytes{page0}).has_value());
  CHECK(volume.write(page_id(7), Bytes{page7}).has_value());
  CHECK(volume.flush().has_value());

  expect_page_eq(volume, page_id(0), page0);
  expect_page_eq(volume, page_id(7), page7);
}

void test_bounds_and_size() {
  MemoryVolume volume(/*page_count=*/2);
  ByteBuffer page(kDefaultPageSize);
  ByteBuffer wrong(kDefaultPageSize - 1);

  CHECK_EQ(volume.read(page_id(2), MutableBytes{page}).error(),
           Error::OutOfRange);
  CHECK_EQ(volume.write(page_id(2), Bytes{page}).error(), Error::OutOfRange);
  CHECK_EQ(volume.read(page_id(0), MutableBytes{wrong}).error(),
           Error::WrongSize);
  CHECK_EQ(volume.write(page_id(0), Bytes{wrong}).error(), Error::WrongSize);
}

void test_file_persistence() {
  const auto dir =
      std::filesystem::temp_directory_path() / "lucia-storage-tests";
  std::filesystem::create_directories(dir);
  const auto path = dir / "lucia.img";
  std::filesystem::remove(path);

  const auto page3 = make_page_pattern(0x33);
  {
    auto created = FileVolume::create(path, /*page_count=*/16);
    CHECK(created.has_value());
    auto& volume = *created;
    CHECK(volume.write(page_id(3), Bytes{page3}).has_value());
    CHECK(volume.flush().has_value());
  }

  {
    auto opened = FileVolume::open(path);
    CHECK(opened.has_value());
    CHECK_EQ(opened->geometry().page_count, 16u);
    expect_page_eq(*opened, page_id(3), page3);
  }

  std::filesystem::remove(path);
}

void test_fault_injection() {
  MemoryVolume memory(/*page_count=*/4);
  FaultyVolume faulty(memory);

  const auto good = make_page_pattern(0xAA);
  CHECK(faulty.write(page_id(1), Bytes{good}).has_value());

  faulty.arm(FaultyVolume::Fault::FailNextWrite);
  CHECK_EQ(faulty.write(page_id(2), Bytes{good}).error(), Error::InjectedFault);
  CHECK(faulty.write(page_id(2), Bytes{good}).has_value());

  faulty.arm(FaultyVolume::Fault::DropNextWrite);
  const auto dropped = make_page_pattern(0xBB);
  CHECK(faulty.write(page_id(1), Bytes{dropped}).has_value());
  expect_page_eq(faulty, page_id(1), good);

  faulty.arm(FaultyVolume::Fault::CorruptNextRead);
  ByteBuffer got(kDefaultPageSize);
  CHECK(faulty.read(page_id(1), MutableBytes{got}).has_value());
  CHECK(got != good);

  faulty.arm(FaultyVolume::Fault::FailNextFlush);
  CHECK_EQ(faulty.flush().error(), Error::FlushFailure);
  CHECK(faulty.flush().has_value());
}

void test_crash_after_n_ops() {
  MemoryVolume memory(/*page_count=*/8);
  FaultyVolume faulty(memory);

  bool crashed = false;
  faulty.crash_after(3, [&] { crashed = true; });

  const auto page = make_page_pattern(1);
  CHECK(faulty.write(page_id(0), Bytes{page}).has_value());
  CHECK(faulty.write(page_id(1), Bytes{page}).has_value());
  CHECK(!crashed);
  CHECK_EQ(faulty.write(page_id(2), Bytes{page}).error(), Error::InjectedFault);
  CHECK(crashed);
  CHECK_EQ(faulty.successful_ops(), 3u);

  // After the injected crash, further ops work again.
  CHECK(faulty.write(page_id(3), Bytes{page}).has_value());
  expect_page_eq(faulty, page_id(0), page);
  expect_page_eq(faulty, page_id(3), page);
}

}  // namespace

int main() {
  test_memory_round_trip();
  test_bounds_and_size();
  test_file_persistence();
  test_fault_injection();
  test_crash_after_n_ops();

  if (g_failures != 0) {
    std::cerr << g_failures << " check(s) failed\n";
    return EXIT_FAILURE;
  }

  std::cout << "All storage volume tests passed\n";
  return EXIT_SUCCESS;
}
