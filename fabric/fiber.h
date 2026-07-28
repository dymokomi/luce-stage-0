#pragma once

#include "texel_id.h"
#include "storage/types.h"

namespace lucia {

// ---------------------------------------------------------------------------
// Fiber
// ---------------------------------------------------------------------------
//
// Reference to one source Texel output.  The target InputPort owns the Fiber.
//
class Fiber {
public:
  Fiber();
  Fiber(const TexelId& source, const char* output_name);

  const TexelId& source() const;
  const String&  output() const;

  bool set_source(const TexelId& texel, const char* output_name);

  bool valid() const;
  bool equals(const Fiber& other) const;

private:
  TexelId source_texel;
  String  output_name;
};

}  // namespace lucia
