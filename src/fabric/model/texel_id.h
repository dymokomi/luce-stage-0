#pragma once

#include "base/types.h"

namespace lucia {

// ---------------------------------------------------------------------------
// TexelId
// ---------------------------------------------------------------------------
//
// Stable 32-byte identity for a Texel.  The all-zero value is unset.
//
class TexelId {
public:
  enum { SIZE = 32, TEXT_SIZE = 64 };

  TexelId();

  bool generate();
  bool parse(const char *text);

  String format() const;

  bool is_unset() const;
  bool equals(const TexelId &other) const;
  bool less_than(const TexelId &other) const;

  const Byte *bytes() const;
  void        set_bytes(const Byte *data);

private:
  Byte id_bytes[SIZE];
};

bool operator<(const TexelId &left, const TexelId &right);

} // namespace lucia
