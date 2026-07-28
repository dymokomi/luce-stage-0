#include "output_port.h"

namespace lucia {

OutputPort::OutputPort()
    : declared_type(VALUE_NONE),
      source_revision(0)
{
}

OutputPort::OutputPort(const char* name, ValueType type)
    : port_name(name != 0 ? name : ""),
      declared_type(type),
      source_revision(0)
{
}

const String& OutputPort::name() const
{
  return port_name;
}

ValueType OutputPort::type() const
{
  return declared_type;
}

bool OutputPort::has_source() const
{
  return source_value.type() != VALUE_NONE;
}

const Value& OutputPort::source() const
{
  return source_value;
}

U64 OutputPort::revision() const
{
  return source_revision;
}

bool OutputPort::set_source(const Value& value)
{
  if (value.type() == VALUE_NONE || value.type() != declared_type) {
    return false;
  }
  source_value = value;
  ++source_revision;
  return true;
}

void OutputPort::clear_source()
{
  if (has_source()) {
    source_value = Value();
    ++source_revision;
  }
}

void OutputPort::set_revision(U64 revision)
{
  source_revision = revision;
}

bool OutputPort::valid() const
{
  if (port_name.empty() ||
      declared_type < VALUE_BOOL ||
      declared_type > VALUE_BLOB) {
    return false;
  }
  return !has_source() || source_value.type() == declared_type;
}

}  // namespace lucia
