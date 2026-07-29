#include "fabric/model/fiber.h"

namespace lucia {

Fiber::Fiber() {}

Fiber::Fiber(const TexelId &source, const char *output_name) {
    set_source(source, output_name);
}

const TexelId &Fiber::source() const {
    return source_texel;
}

const String &Fiber::output() const {
    return output_name;
}

bool Fiber::set_source(const TexelId &texel, const char *output_name) {
    if (texel.is_unset() || output_name == 0 || output_name[0] == '\0') {
        return false;
    }
    source_texel      = texel;
    this->output_name = output_name;
    return true;
}

bool Fiber::valid() const {
    return !source_texel.is_unset() && !output_name.empty();
}

bool Fiber::equals(const Fiber &other) const {
    return source_texel.equals(other.source_texel) && output_name == other.output_name;
}

} // namespace lucia
