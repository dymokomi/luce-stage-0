#pragma once

#include "node_id.h"
#include "types.h"

namespace lucia {

// ---------------------------------------------------------------------------
// Fiber
// ---------------------------------------------------------------------------
//
// Connects one output port on a source node to one input port on a target.
// One source per target input.  Scaffold only.
//
class Fiber {
public:
  Fiber();

  const NodeId& source() const;
  const String& source_port() const;
  const NodeId& target() const;
  const String& target_port() const;

  void set_source(const NodeId& node, const char* port_name);
  void set_target(const NodeId& node, const char* port_name);

  bool equals(const Fiber& other) const;

private:
  NodeId source_node;
  String source_port_name;
  NodeId target_node;
  String target_port_name;
};

}  // namespace lucia
