#pragma once

#include "types.h"

namespace lucia {

// ---------------------------------------------------------------------------
// NodeId
// ---------------------------------------------------------------------------
//
// Stable node identity.  Independent of address (where a node currently sits).
// References store identity; addresses resolve on demand.
// See planning/LOOM.md.
//
class NodeId {
public:
  NodeId();

  // All-zero id: unset / invalid.
  bool is_unset() const;

  bool equals(const NodeId& other) const;
  bool less_than(const NodeId& other) const;

  // Raw 32-byte identity.  Filled by fabric when a node is created.
  const Byte* bytes() const;
  void        set_bytes(const Byte* data);

  enum { SIZE = 32 };

private:
  Byte id_bytes[SIZE];
};

bool operator<(const NodeId& a, const NodeId& b);

}  // namespace lucia
