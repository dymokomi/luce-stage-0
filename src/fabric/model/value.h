#pragma once

#include "base/types.h"
#include "fabric/model/blob_ref.h"
#include "fabric/model/texel_id.h"

namespace lucia {

// ---------------------------------------------------------------------------
// ValueType
// ---------------------------------------------------------------------------
//
enum ValueType {
    VALUE_NONE  = 0,
    VALUE_BOOL  = 1,
    VALUE_INT   = 2,
    VALUE_REAL  = 3,
    VALUE_TEXT  = 4,
    VALUE_BYTES = 5,
    VALUE_TEXEL = 6,
    VALUE_BLOB  = 7
};

// ---------------------------------------------------------------------------
// Value
// ---------------------------------------------------------------------------
//
// One typed Fabric value.  VALUE_NONE represents no value.
//
class Value {
public:
    Value();
    explicit Value(bool value);
    explicit Value(int value);
    explicit Value(S64 value);
    explicit Value(double value);
    explicit Value(const char *text);
    explicit Value(const String &text);
    Value(const Byte *data, Size size);
    explicit Value(const Bytes &data);
    explicit Value(const TexelId &texel);
    explicit Value(const BlobRef &blob);

    ValueType type() const;

    bool           boolean() const;
    S64            integer() const;
    double         real() const;
    const String  &text() const;
    const Bytes   &bytes() const;
    const TexelId &texel() const;
    const BlobRef &blob() const;

    bool equals(const Value &other) const;

private:
    ValueType value_type;
    bool      bool_value;
    S64       int_value;
    double    real_value;
    String    text_value;
    Bytes     bytes_value;
    TexelId   texel_value;
    BlobRef   blob_value;
};

} // namespace lucia
