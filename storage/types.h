#pragma once

#include <stddef.h>
#include <stdint.h>
#include <vector>

namespace lucia {

// Fixed-width integers
typedef uint8_t  Byte;
typedef uint32_t U32;
typedef uint64_t U64;
typedef int64_t  S64;

// Memory sizes and indexes
typedef size_t Size;

// Growable byte buffer
typedef std::vector<Byte> Bytes;

}  // namespace lucia
