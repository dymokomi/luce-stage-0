#include "lucia/storage/faulty_volume.hpp"

namespace lucia::storage {

FaultyVolume::FaultyVolume(Volume& inner) : inner_(inner) {}

Geometry FaultyVolume::geometry() const noexcept {
  return inner_.geometry();
}

void FaultyVolume::arm(Fault fault) noexcept {
  fault_ = fault;
}

void FaultyVolume::clear_fault() noexcept {
  fault_ = Fault::None;
}

void FaultyVolume::crash_after(std::uint64_t count,
                               std::function<void()> on_crash) {
  crash_after_ = count;
  on_crash_ = std::move(on_crash);
}

std::uint64_t FaultyVolume::successful_ops() const noexcept {
  return successful_ops_;
}

Status FaultyVolume::maybe_crash() {
  if (!crash_after_.has_value()) {
    return {};
  }

  ++successful_ops_;
  if (successful_ops_ < *crash_after_) {
    return {};
  }

  crash_after_.reset();
  if (on_crash_) {
    on_crash_();
  }
  return std::unexpected(Error::InjectedFault);
}

Status FaultyVolume::read(PageId page, MutableBytes destination) {
  const Fault fault = fault_;
  if (fault == Fault::FailNextRead || fault == Fault::CorruptNextRead) {
    fault_ = Fault::None;
  }

  if (fault == Fault::FailNextRead) {
    return std::unexpected(Error::InjectedFault);
  }

  auto status = inner_.read(page, destination);
  if (!status) {
    return status;
  }

  if (fault == Fault::CorruptNextRead && !destination.empty()) {
    const auto index = destination.size() / 2;
    destination[index] ^= std::byte{0x01};
  }

  return {};
}

Status FaultyVolume::write(PageId page, Bytes source) {
  const Fault fault = fault_;
  if (fault == Fault::FailNextWrite || fault == Fault::DropNextWrite ||
      fault == Fault::FullOnNextWrite) {
    fault_ = Fault::None;
  }

  if (fault == Fault::FailNextWrite) {
    return std::unexpected(Error::InjectedFault);
  }
  if (fault == Fault::FullOnNextWrite) {
    return std::unexpected(Error::Full);
  }
  if (fault == Fault::DropNextWrite) {
    return maybe_crash();
  }

  if (auto status = inner_.write(page, source); !status) {
    return status;
  }
  return maybe_crash();
}

Status FaultyVolume::flush() {
  const Fault fault = fault_;
  if (fault == Fault::FailNextFlush) {
    fault_ = Fault::None;
    return std::unexpected(Error::FlushFailure);
  }

  if (auto status = inner_.flush(); !status) {
    return status;
  }
  return maybe_crash();
}

}  // namespace lucia::storage
