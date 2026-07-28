#pragma once

#include "storage/types.h"

namespace lucia {

// ---------------------------------------------------------------------------
// BlobRef
// ---------------------------------------------------------------------------
//
// Content identifier and byte size for a blob stored outside a Value.
//
class BlobRef {
public:
  enum { ID_SIZE = 32 };

  BlobRef();
  BlobRef(const Byte* identifier, U64 byte_size);

  bool is_unset() const;
  bool equals(const BlobRef& other) const;

  const Byte* id() const;
  U64         size() const;

  void set_id(const Byte* identifier);
  void set_size(U64 byte_size);

private:
  Byte blob_id[ID_SIZE];
  U64  byte_size;
};

}  // namespace lucia
