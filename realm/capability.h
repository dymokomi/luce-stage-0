#pragma once

#include "fabric/value.h"
#include "storage/types.h"

#include <map>

namespace lucia {

class Authority;

// ---------------------------------------------------------------------------
// Capability
// ---------------------------------------------------------------------------
//
// An opaque bearer token for one exact operation and scope.  Tokens are
// meaningful only to the local Authority which issued them.  This boundary
// uses process randomness and an in-memory grant table; it is not production
// cryptography and is not suitable for authority across trust domains.
//
class Capability {
public:
  enum { TOKEN_SIZE = 32 };

  Capability();

  const String& operation() const;
  const String& scope() const;
  bool          valid() const;

private:
  friend class Authority;
  friend bool encode_capability(const Capability& capability, Value* value);
  friend bool decode_capability(const Value& value, Capability* capability);

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
// Local issuer and verifier.  Its grant table must remain private to trusted
// Loom code and live at least as long as boundaries which use it.
//
class Authority {
public:
  bool issue(const char* operation, const char* scope,
             Capability* capability);
  bool verify(const Capability& capability, const char* operation,
              const char* scope) const;

private:
  CapabilityGrantTable grants;
};

// Deterministic, versioned VALUE_BYTES encoding.  Decode is strict and
// consumes the complete payload.
bool encode_capability(const Capability& capability, Value* value);
bool decode_capability(const Value& value, Capability* capability);

}  // namespace lucia
