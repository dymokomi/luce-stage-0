#pragma once

#include "lucia/storage/bytes.hpp"
#include "lucia/storage/error.hpp"
#include "lucia/storage/geometry.hpp"
#include "lucia/storage/page.hpp"

namespace lucia::storage {

/// Fixed-page durable storage boundary.
///
/// Higher layers (segments, objects, documents) depend only on this contract.
/// Implementations may be an in-memory image, a host file, a raw partition,
/// or a future virtio/NVMe driver. The repository must not know which.
///
/// Assumptions callers must honor:
/// - writes can fail
/// - writes may be reordered until flush()
/// - a crash may tear a write
/// - durability requires a successful flush()
class Volume {
 public:
  virtual ~Volume() = default;

  Volume(const Volume&) = delete;
  Volume& operator=(const Volume&) = delete;
  Volume(Volume&&) = delete;
  Volume& operator=(Volume&&) = delete;

  [[nodiscard]] virtual Geometry geometry() const noexcept = 0;

  /// Read exactly one page into `destination`.
  /// `destination.size()` must equal `geometry().page_size`.
  [[nodiscard]] virtual Status read(PageId page, MutableBytes destination) = 0;

  /// Write exactly one page from `source`.
  /// Durability is not guaranteed until flush() succeeds.
  [[nodiscard]] virtual Status write(PageId page, Bytes source) = 0;

  /// Push prior successful writes to durable media when supported.
  [[nodiscard]] virtual Status flush() = 0;

 protected:
  Volume() = default;
};

}  // namespace lucia::storage
