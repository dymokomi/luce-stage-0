#pragma once

#include "node_id.h"
#include "port.h"
#include "types.h"

namespace lucia {

typedef std::map<String, Port> PortMap;

// ---------------------------------------------------------------------------
// Node
// ---------------------------------------------------------------------------
//
// The only thing that exists in the Fabric: identity and ports.
// Port values are the content.  See planning/LOOM.md.
//
class Node {
public:
  Node();

  const NodeId& id() const;
  void          set_id(const NodeId& id);

  Size size() const;   // port count

  bool has   (const char* port_name) const;
  bool get   (const char* port_name, Port* port) const;
  bool put   (const Port& port);
  bool remove(const char* port_name);

  bool at(Size index, Port* port) const;

private:
  NodeId  node_id;
  PortMap ports;
};

}  // namespace lucia
