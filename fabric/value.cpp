#include "value.h"

namespace lucia {

namespace {

const String empty_string;
const Bytes  empty_bytes;

}  // namespace

Value::Value()
    : value_kind(VALUE_EMPTY),
      int_value(0)
{
}

Value::Value(bool value)
    : value_kind(VALUE_BOOL),
      bool_value(value)
{
}

Value::Value(int value)
    : value_kind(VALUE_INT),
      int_value(value)
{
}

Value::Value(S64 value)
    : value_kind(VALUE_INT),
      int_value(value)
{
}

Value::Value(double value)
    : value_kind(VALUE_FLOAT),
      float_value(value)
{
}

Value::Value(const char* text)
    : value_kind(VALUE_STRING),
      string_value(new String(text != 0 ? text : ""))
{
}

Value::Value(const String& text)
    : value_kind(VALUE_STRING),
      string_value(new String(text))
{
}

Value::Value(const Byte* data, Size size)
    : value_kind(VALUE_BYTES),
      bytes_value(new Bytes())
{
  if (data != 0 && size > 0) {
    bytes_value->assign(data, data + size);
  }
}

Value::Value(const Bytes& data)
    : value_kind(VALUE_BYTES),
      bytes_value(new Bytes(data))
{
}

Value::Value(const Value& other)
    : value_kind(VALUE_EMPTY),
      int_value(0)
{
  copy_from(other);
}

Value& Value::operator=(const Value& other)
{
  if (this != &other) {
    clear();
    copy_from(other);
  }
  return *this;
}

Value::~Value()
{
  clear();
}

void Value::clear()
{
  if (value_kind == VALUE_STRING) {
    delete string_value;
    string_value = 0;
  } else if (value_kind == VALUE_BYTES) {
    delete bytes_value;
    bytes_value = 0;
  }

  value_kind = VALUE_EMPTY;
  int_value = 0;
}

void Value::copy_from(const Value& other)
{
  value_kind = other.value_kind;

  switch (other.value_kind) {
  case VALUE_EMPTY:
    int_value = 0;
    break;
  case VALUE_BOOL:
    bool_value = other.bool_value;
    break;
  case VALUE_INT:
    int_value = other.int_value;
    break;
  case VALUE_FLOAT:
    float_value = other.float_value;
    break;
  case VALUE_STRING:
    string_value = new String(*other.string_value);
    break;
  case VALUE_BYTES:
    bytes_value = new Bytes(*other.bytes_value);
    break;
  }
}

ValueKind Value::kind() const
{
  return value_kind;
}

bool Value::boolean() const
{
  if (value_kind != VALUE_BOOL) {
    return false;
  }
  return bool_value;
}

S64 Value::integer() const
{
  if (value_kind != VALUE_INT) {
    return 0;
  }
  return int_value;
}

double Value::real() const
{
  if (value_kind != VALUE_FLOAT) {
    return 0.0;
  }
  return float_value;
}

const String& Value::text() const
{
  if (value_kind != VALUE_STRING || string_value == 0) {
    return empty_string;
  }
  return *string_value;
}

const Bytes& Value::bytes() const
{
  if (value_kind != VALUE_BYTES || bytes_value == 0) {
    return empty_bytes;
  }
  return *bytes_value;
}

bool Value::equals(const Value& other) const
{
  if (value_kind != other.value_kind) {
    return false;
  }

  switch (value_kind) {
  case VALUE_EMPTY:
    return true;
  case VALUE_BOOL:
    return bool_value == other.bool_value;
  case VALUE_INT:
    return int_value == other.int_value;
  case VALUE_FLOAT:
    return float_value == other.float_value;
  case VALUE_STRING:
    return *string_value == *other.string_value;
  case VALUE_BYTES:
    return *bytes_value == *other.bytes_value;
  }

  return false;
}

}  // namespace lucia
