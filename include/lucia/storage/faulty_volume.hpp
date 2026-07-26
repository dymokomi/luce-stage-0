#pragma once

#include <cstdint>
#include <functional>
#include <optional>

#include "lucia/storage/volume.hpp"

namespace lucia::storage {

/// Deterministic fault injector wrapped around another Volume.
///
/// Used to prove recovery logic later: lose writes, fail flushes,
/// corrupt pages, or "crash" after N successful operations.
class FaultyVolume final : public Volume {
 public:
  enum class Fault : std::uint8_t {
    None,
    FailNextRead,
    FailNextWrite,
    FailNextFlush,
    CorruptNextRead,   // deliver bytes, but flip one bit first
    DropNextWrite,     // report success without mutating storage
    FullOnNextWrite,
  };

  explicit FaultyVolume(Volume& inner);

  [[nodiscard]] Geometry geometry() const noexcept override;
  [[nodiscard]] Status read(PageId page, MutableBytes destination) override;
  [[nodiscard]] Status write(PageId page, Bytes source) override;
  [[nodiscard]] Status flush() override;

  void arm(Fault fault) noexcept;
  void clear_fault() noexcept;

  /// After `count` successful write() or flush() calls, invoke `on_crash`
  /// and return InjectedFault from the triggering call.
  /// Counts only operations that would otherwise succeed.
  void crash_after(std::uint64_t count, std::function<void()> on_crash);

  [[nodiscard]] std::uint64_t successful_ops() const noexcept;

 private:
  [[nodiscard]] Status maybe_crash();

  Volume& inner_;
  Fault fault_ = Fault::None;
  std::uint64_t successful_ops_ = 0;
  std::optional<std::uint64_t> crash_after_;
  std::function<void()> on_crash_;
};

}  // namespace lucia::storage
