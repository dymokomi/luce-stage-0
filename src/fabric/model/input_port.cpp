#include "fabric/model/input_port.h"

namespace lucia {

InputPort::InputPort() : declared_type(VALUE_NONE), bound(false) {}

InputPort::InputPort(const char *name, ValueType type)
    : port_name(name != 0 ? name : ""), declared_type(type), bound(false) {}

const String &InputPort::name() const {
    return port_name;
}

ValueType InputPort::type() const {
    return declared_type;
}

bool InputPort::has_binding() const {
    return bound;
}

const Fiber &InputPort::binding() const {
    return source_binding;
}

bool InputPort::bind(const Fiber &fiber) {
    if (!fiber.valid()) {
        return false;
    }
    source_binding = fiber;
    bound          = true;
    return true;
}

void InputPort::unbind() {
    source_binding = Fiber();
    bound          = false;
}

bool InputPort::valid() const {
    if (port_name.empty() || declared_type < VALUE_BOOL || declared_type > VALUE_BLOB) {
        return false;
    }
    return !bound || source_binding.valid();
}

} // namespace lucia
