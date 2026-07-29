#pragma once

#include "base/types.h"
#include "fabric/model/value.h"

#include <map>

namespace lucia {

class Authority;

// ---------------------------------------------------------------------------
// Capability
// ---------------------------------------------------------------------------
//
// An opaque bearer token for one exact operation and scope.  Tokens are
// meaningful only to the local Authority which issued them.  This boundary
// uses process randomness and a local grant table; it is not production
// cryptography and is not suitable for authority across trust domains.
//
class Capability {
public:
    enum { TOKEN_SIZE = 32 };

    Capability();

    const String &operation() const;
    const String &scope() const;
    bool          valid() const;

private:
    friend class Authority;
    friend bool encode_capability(const Capability &capability, Value *value);
    friend bool decode_capability(const Value &value, Capability *capability);

    Byte   token[TOKEN_SIZE];
    String allowed_operation;
    String allowed_scope;
};

struct CapabilityGrant {
    String operation;
    String scope;
};

typedef std::map<String, CapabilityGrant> CapabilityGrantTable;

// ---------------------------------------------------------------------------
// Authority
// ---------------------------------------------------------------------------
//
// Local issuer and verifier. The grant table can be encoded into a trusted
// authority Texel and restored after restart.
//
class Authority {
public:
    bool issue(const char *operation, const char *scope, Capability *capability);
    bool verify(const Capability &capability, const char *operation,
                const char *scope) const;
    Size size() const;

    bool encode(Value *value) const;
    bool restore(const Value &value);

private:
    CapabilityGrantTable grants;
};

// Deterministic, versioned VALUE_BYTES encoding.  Decode is strict and
// consumes the complete payload.
bool encode_capability(const Capability &capability, Value *value);
bool decode_capability(const Value &value, Capability *capability);

} // namespace lucia
