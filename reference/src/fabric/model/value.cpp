#include "fabric/model/value.h"

namespace lucia {

Value::Value() : value_type(VALUE_NONE), bool_value(false), int_value(0), real_value(0.0) {}

Value::Value(bool value)
    : value_type(VALUE_BOOL), bool_value(value), int_value(0), real_value(0.0) {}

Value::Value(int value)
    : value_type(VALUE_INT), bool_value(false), int_value(value), real_value(0.0) {}

Value::Value(S64 value)
    : value_type(VALUE_INT), bool_value(false), int_value(value), real_value(0.0) {}

Value::Value(double value)
    : value_type(VALUE_REAL), bool_value(false), int_value(0), real_value(value) {}

Value::Value(const char *text)
    : value_type(VALUE_TEXT), bool_value(false), int_value(0), real_value(0.0),
      text_value(text != 0 ? text : "") {}

Value::Value(const String &text)
    : value_type(VALUE_TEXT), bool_value(false), int_value(0), real_value(0.0),
      text_value(text) {}

Value::Value(const Byte *data, Size size)
    : value_type(VALUE_BYTES), bool_value(false), int_value(0), real_value(0.0) {
    if (data != 0 && size > 0) {
        bytes_value.assign(data, data + size);
    }
}

Value::Value(const Bytes &data)
    : value_type(VALUE_BYTES), bool_value(false), int_value(0), real_value(0.0),
      bytes_value(data) {}

Value::Value(const TexelId &texel)
    : value_type(VALUE_TEXEL), bool_value(false), int_value(0), real_value(0.0),
      texel_value(texel) {}

Value::Value(const BlobRef &blob)
    : value_type(VALUE_BLOB), bool_value(false), int_value(0), real_value(0.0),
      blob_value(blob) {}

ValueType Value::type() const {
    return value_type;
}

bool Value::boolean() const {
    if (value_type != VALUE_BOOL) {
        return false;
    }
    return bool_value;
}

S64 Value::integer() const {
    if (value_type != VALUE_INT) {
        return 0;
    }
    return int_value;
}

double Value::real() const {
    if (value_type != VALUE_REAL) {
        return 0.0;
    }
    return real_value;
}

const String &Value::text() const {
    return text_value;
}

const Bytes &Value::bytes() const {
    return bytes_value;
}

const TexelId &Value::texel() const {
    return texel_value;
}

const BlobRef &Value::blob() const {
    return blob_value;
}

bool Value::equals(const Value &other) const {
    if (value_type != other.value_type) {
        return false;
    }

    switch (value_type) {
    case VALUE_NONE:
        return true;
    case VALUE_BOOL:
        return bool_value == other.bool_value;
    case VALUE_INT:
        return int_value == other.int_value;
    case VALUE_REAL:
        return real_value == other.real_value;
    case VALUE_TEXT:
        return text_value == other.text_value;
    case VALUE_BYTES:
        return bytes_value == other.bytes_value;
    case VALUE_TEXEL:
        return texel_value.equals(other.texel_value);
    case VALUE_BLOB:
        return blob_value.equals(other.blob_value);
    }

    return false;
}

} // namespace lucia
