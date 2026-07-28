#pragma once

#include "types.h"
#include "value.h"

namespace lucia {

// ---------------------------------------------------------------------------
// PortDirection
// ---------------------------------------------------------------------------
//
enum PortDirection {
  PORT_IN  = 0,
  PORT_OUT = 1
};

// ---------------------------------------------------------------------------
// Port
// ---------------------------------------------------------------------------
//
// A named, typed slot on a node.  Holds a cached Value.  Fibers connect one
// output port to one input port.
//
class Port {
public:
  Port();
  Port(const char* name, PortDirection direction);
  Port(const char* name, PortDirection direction, const Value& value);

  const String&  name() const;
  PortDirection  direction() const;
  const Value&   value() const;

  void set_name(const char* name);
  void set_direction(PortDirection direction);
  void set_value(const Value& value);

private:
  String        port_name;
  PortDirection port_direction;
  Value         port_value;
};

}  // namespace lucia
