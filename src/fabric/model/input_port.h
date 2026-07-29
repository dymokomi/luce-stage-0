#pragma once

#include "fabric/model/fiber.h"
#include "fabric/model/value.h"

namespace lucia {

// ---------------------------------------------------------------------------
// InputPort
// ---------------------------------------------------------------------------
//
// Named, typed input which owns zero or one source binding.
//
class InputPort {
public:
  InputPort();
  InputPort(const char *name, ValueType type);

  const String &name() const;
  ValueType     type() const;

  bool         has_binding() const;
  const Fiber &binding() const;

  bool bind(const Fiber &fiber);
  void unbind();

  bool valid() const;

private:
  String    port_name;
  ValueType declared_type;
  bool      bound;
  Fiber     source_binding;
};

} // namespace lucia
