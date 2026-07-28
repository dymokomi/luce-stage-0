#pragma once

#include "value.h"

namespace lucia {

// ---------------------------------------------------------------------------
// OutputPort
// ---------------------------------------------------------------------------
//
// Named, typed output which owns its current source Value and revision.
//
class OutputPort {
public:
  OutputPort();
  OutputPort(const char* name, ValueType type);

  const String& name() const;
  ValueType     type() const;

  bool         has_source() const;
  const Value& source() const;
  U64          revision() const;

  bool set_source(const Value& value);
  void clear_source();
  void set_revision(U64 revision);

  bool valid() const;

private:
  String    port_name;
  ValueType declared_type;
  Value     source_value;
  U64       source_revision;
};

}  // namespace lucia
