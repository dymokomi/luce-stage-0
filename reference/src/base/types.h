#pragma once

#include <map>
#include <stddef.h>
#include <stdint.h>
#include <string>
#include <vector>

namespace lucia {

// Fixed-width integers
typedef uint8_t  Byte;
typedef uint32_t U32;
typedef uint64_t U64;
typedef int64_t  S64;

// Memory sizes and indexes
typedef size_t Size;

// Standard containers — prefer these names; avoid writing std:: in Lucia code.
typedef std::string         String;
typedef std::vector<Byte>   Bytes;
typedef std::vector<String> Strings;

} // namespace lucia
