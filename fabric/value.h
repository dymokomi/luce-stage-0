#pragma once

#include "types.h"

namespace lucia {

// ---------------------------------------------------------------------------
// ValueKind
// ---------------------------------------------------------------------------
//
enum ValueKind {
  VALUE_EMPTY  = 0,
  VALUE_BOOL   = 1,
  VALUE_INT    = 2,
  VALUE_FLOAT  = 3,
  VALUE_STRING = 4,
  VALUE_BYTES  = 5
};

// ---------------------------------------------------------------------------
// Value
// ---------------------------------------------------------------------------
//
// Typed payload cached on a Port.  Scalars live inline; string and bytes
// heap-allocate only when that kind is active.  NodeId-as-value comes later.
//
class Value {
public:
  Value();
  explicit Value(bool value);
  explicit Value(int value);
  explicit Value(S64 value);
  explicit Value(double value);
  explicit Value(const char* text);
  explicit Value(const String& text);
  Value(const Byte* data, Size size);
  explicit Value(const Bytes& data);

  Value(const Value& other);
  Value& operator=(const Value& other);
  ~Value();

  ValueKind kind() const;

  bool          boolean() const;
  S64           integer() const;
  double        real() const;
  const String& text() const;
  const Bytes&  bytes() const;

  bool equals(const Value& other) const;

private:
  void clear();
  void copy_from(const Value& other);

  ValueKind value_kind;

  union {
    bool    bool_value;
    S64     int_value;
    double  float_value;
    String* string_value;
    Bytes*  bytes_value;
  };
};

}  // namespace lucia
