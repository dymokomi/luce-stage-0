#pragma once

#include <cstdint>
#include <expected>
#include <string_view>

namespace lucia::storage {

/// Explicit failures for durable page I/O.
/// Callers must not treat these as "not found" or quiet no-ops.
enum class Error : std::uint8_t {
  OutOfRange,     // page id beyond volume geometry
  WrongSize,      // buffer length != page size
  IoFailure,      // underlying read/write/open failed
  FlushFailure,   // durability barrier failed
  Full,           // simulated or real capacity exhaustion
  InjectedFault,  // FaultyVolume deliberately failed the call
  Closed,         // volume is no longer usable
};

[[nodiscard]] constexpr std::string_view to_string(Error error) noexcept {
  switch (error) {
    case Error::OutOfRange:
      return "out of range";
    case Error::WrongSize:
      return "wrong size";
    case Error::IoFailure:
      return "I/O failure";
    case Error::FlushFailure:
      return "flush failure";
    case Error::Full:
      return "full";
    case Error::InjectedFault:
      return "injected fault";
    case Error::Closed:
      return "closed";
  }
  return "unknown";
}

template <typename T>
using Result = std::expected<T, Error>;

using Status = Result<void>;

}  // namespace lucia::storage
