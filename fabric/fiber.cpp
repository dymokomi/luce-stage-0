#include "fiber.h"

namespace lucia {

Fiber::Fiber()
{
}

const NodeId& Fiber::source() const
{
  return source_node;
}

const String& Fiber::source_port() const
{
  return source_port_name;
}

const NodeId& Fiber::target() const
{
  return target_node;
}

const String& Fiber::target_port() const
{
  return target_port_name;
}

void Fiber::set_source(const NodeId& node, const char* port_name)
{
  source_node = node;
  source_port_name = (port_name != 0) ? port_name : "";
}

void Fiber::set_target(const NodeId& node, const char* port_name)
{
  target_node = node;
  target_port_name = (port_name != 0) ? port_name : "";
}

bool Fiber::equals(const Fiber& other) const
{
  return source_node.equals(other.source_node) &&
         target_node.equals(other.target_node) &&
         source_port_name == other.source_port_name &&
         target_port_name == other.target_port_name;
}

}  // namespace lucia
