#pragma once

#include <cstdint>

namespace lucia::storage {

/// Physical address of one storage page inside a volume.
/// Private to the storage layer; never part of document identity.
enum class PageId : std::uint64_t {};

[[nodiscard]] constexpr PageId page_id(std::uint64_t value) noexcept {
  return PageId{value};
}

[[nodiscard]] constexpr std::uint64_t to_u64(PageId id) noexcept {
  return static_cast<std::uint64_t>(id);
}

/// Default Prism storage page size.
/// Addressing and validation unit; I/O may batch many pages later.
inline constexpr std::uint32_t kDefaultPageSize = 4096;

}  // namespace lucia::storage
