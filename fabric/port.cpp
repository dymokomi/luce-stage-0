#include "port.h"

namespace lucia {

Port::Port()
    : port_direction(PORT_IN)
{
}

Port::Port(const char* name, PortDirection direction)
    : port_name(name != 0 ? name : ""),
      port_direction(direction)
{
}

Port::Port(const char* name, PortDirection direction, const Value& value)
    : port_name(name != 0 ? name : ""),
      port_direction(direction),
      port_value(value)
{
}

const String& Port::name() const
{
  return port_name;
}

PortDirection Port::direction() const
{
  return port_direction;
}

const Value& Port::value() const
{
  return port_value;
}

void Port::set_name(const char* name)
{
  port_name = (name != 0) ? name : "";
}

void Port::set_direction(PortDirection direction)
{
  port_direction = direction;
}

void Port::set_value(const Value& value)
{
  port_value = value;
}

}  // namespace lucia
