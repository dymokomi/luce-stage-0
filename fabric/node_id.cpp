#include "node_id.h"

#include <string.h>

namespace lucia {

NodeId::NodeId()
{
  memset(id_bytes, 0, SIZE);
}

bool NodeId::is_unset() const
{
  for (Size i = 0; i < SIZE; ++i) {
    if (id_bytes[i] != 0) {
      return false;
    }
  }
  return true;
}

bool NodeId::equals(const NodeId& other) const
{
  return memcmp(id_bytes, other.id_bytes, SIZE) == 0;
}

bool NodeId::less_than(const NodeId& other) const
{
  return memcmp(id_bytes, other.id_bytes, SIZE) < 0;
}

const Byte* NodeId::bytes() const
{
  return id_bytes;
}

void NodeId::set_bytes(const Byte* data)
{
  if (data == 0) {
    memset(id_bytes, 0, SIZE);
    return;
  }
  memcpy(id_bytes, data, SIZE);
}

bool operator<(const NodeId& a, const NodeId& b)
{
  return a.less_than(b);
}

}  // namespace lucia
