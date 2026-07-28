#include "fabric/model/blob_ref.h"

#include <string.h>

namespace lucia {

BlobRef::BlobRef() : byte_size(0) {
  memset(blob_id, 0, ID_SIZE);
}

BlobRef::BlobRef(const Byte *identifier, U64 byte_size) : byte_size(byte_size) {
  set_id(identifier);
}

bool BlobRef::is_unset() const {
  for (Size i = 0; i < ID_SIZE; ++i) {
    if (blob_id[i] != 0) {
      return false;
    }
  }
  return true;
}

bool BlobRef::equals(const BlobRef &other) const {
  return byte_size == other.byte_size && memcmp(blob_id, other.blob_id, ID_SIZE) == 0;
}

const Byte *BlobRef::id() const {
  return blob_id;
}

U64 BlobRef::size() const {
  return byte_size;
}

void BlobRef::set_id(const Byte *identifier) {
  if (identifier == 0) {
    memset(blob_id, 0, ID_SIZE);
    return;
  }
  memcpy(blob_id, identifier, ID_SIZE);
}

void BlobRef::set_size(U64 byte_size) {
  this->byte_size = byte_size;
}

} // namespace lucia
