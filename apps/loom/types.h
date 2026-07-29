#pragma once

#include <map>
#include <stddef.h>
#include <stdint.h>
#include <string>
#include <vector>

// The terminal's own aliases; the app depends on abi/loom.h alone, never
// on the reference engine tree.
namespace lucia {

typedef uint8_t  Byte;
typedef uint32_t U32;
typedef uint64_t U64;
typedef int64_t  S64;
typedef size_t   Size;

typedef std::string         String;
typedef std::vector<Byte>   Bytes;
typedef std::vector<String> Strings;

} // namespace lucia
