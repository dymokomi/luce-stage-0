#pragma once

#include <cstddef>
#include <span>
#include <vector>

namespace lucia::storage {

/// Borrowed immutable bytes.
using Bytes = std::span<const std::byte>;

/// Borrowed mutable bytes.
using MutableBytes = std::span<std::byte>;

/// Owned byte buffer.
using ByteBuffer = std::vector<std::byte>;

}  // namespace lucia::storage
