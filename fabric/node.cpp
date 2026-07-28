#include "node.h"

namespace lucia {

Node::Node()
{
}

const NodeId& Node::id() const
{
  return node_id;
}

void Node::set_id(const NodeId& id)
{
  node_id = id;
}

Size Node::size() const
{
  return ports.size();
}

bool Node::has(const char* port_name) const
{
  if (port_name == 0) {
    return false;
  }
  return ports.find(port_name) != ports.end();
}

bool Node::get(const char* port_name, Port* port) const
{
  if (port_name == 0 || port == 0) {
    return false;
  }

  PortMap::const_iterator found = ports.find(port_name);
  if (found == ports.end()) {
    return false;
  }

  *port = found->second;
  return true;
}

bool Node::put(const Port& port)
{
  if (port.name().empty()) {
    return false;
  }
  ports[port.name()] = port;
  return true;
}

bool Node::remove(const char* port_name)
{
  if (port_name == 0) {
    return false;
  }
  return ports.erase(port_name) > 0;
}

bool Node::at(Size index, Port* port) const
{
  if (port == 0 || index >= ports.size()) {
    return false;
  }

  PortMap::const_iterator found = ports.begin();
  for (Size i = 0; i < index; ++i) {
    ++found;
  }

  *port = found->second;
  return true;
}

}  // namespace lucia
