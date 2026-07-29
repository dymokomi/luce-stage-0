#include "realm/authority/capability.h"

#include <limits.h>
#include <random>
#include <string.h>

namespace lucia {

namespace {

enum {
    CAPABILITY_VERSION    = 1,
    CAPABILITY_MAGIC_SIZE = 8,
    MAX_NAME_SIZE         = 4096,
    MAX_GRANT_COUNT       = 65536
};

const Byte CAPABILITY_MAGIC[CAPABILITY_MAGIC_SIZE] = {'L', 'U',  'C',  'A',
                                                      'P', '\0', '\0', '\0'};
const Byte AUTHORITY_MAGIC[CAPABILITY_MAGIC_SIZE]  = {'L', 'U', 'A',  'U',
                                                      'T', 'H', '\0', '\0'};

bool valid_name(const String &name) {
    return !name.empty() && name.size() <= MAX_NAME_SIZE && name.find('\0') == String::npos;
}

bool token_is_zero(const Byte *token) {
    for (Size i = 0; i < Capability::TOKEN_SIZE; ++i) {
        if (token[i] != 0) {
            return false;
        }
    }
    return true;
}

String token_key(const Byte *token) {
    return String(reinterpret_cast<const char *>(token), Capability::TOKEN_SIZE);
}

void write_u32(Bytes *bytes, U32 value) {
    for (int i = 0; i < 4; ++i) {
        bytes->push_back(static_cast<Byte>((value >> (i * 8)) & 0xffu));
    }
}

bool read_u32(const Bytes &bytes, Size *offset, U32 *value) {
    if (offset == 0 || value == 0 || *offset > bytes.size() || bytes.size() - *offset < 4) {
        return false;
    }
    const Byte *data = bytes.data() + *offset;
    *value           = static_cast<U32>(data[0]) | (static_cast<U32>(data[1]) << 8) |
             (static_cast<U32>(data[2]) << 16) | (static_cast<U32>(data[3]) << 24);
    *offset += 4;
    return true;
}

bool read_string(const Bytes &bytes, Size *offset, String *text) {
    U32 size = 0;
    if (text == 0 || !read_u32(bytes, offset, &size) || size > MAX_NAME_SIZE ||
        *offset > bytes.size() || static_cast<Size>(size) > bytes.size() - *offset) {
        return false;
    }
    text->assign(reinterpret_cast<const char *>(bytes.data() + *offset), size);
    *offset += size;
    return valid_name(*text);
}

} // namespace

Capability::Capability() {
    memset(token, 0, sizeof(token));
}

const String &Capability::operation() const {
    return allowed_operation;
}

const String &Capability::scope() const {
    return allowed_scope;
}

bool Capability::valid() const {
    return !token_is_zero(token) && valid_name(allowed_operation) &&
           valid_name(allowed_scope);
}

bool Authority::issue(const char *operation, const char *scope, Capability *capability) {
    if (operation == 0 || scope == 0 || capability == 0) {
        return false;
    }

    const String operation_text(operation);
    const String scope_text(scope);
    if (!valid_name(operation_text) || !valid_name(scope_text)) {
        return false;
    }

    std::random_device random;
    Byte               token[Capability::TOKEN_SIZE];
    String             key;
    do {
        for (Size i = 0; i < sizeof(token); ++i) {
            token[i] = static_cast<Byte>(random());
        }
        key = token_key(token);
    } while (token_is_zero(token) || grants.find(key) != grants.end());

    CapabilityGrant grant;
    grant.operation = operation_text;
    grant.scope     = scope_text;
    grants[key]     = grant;

    Capability issued;
    memcpy(issued.token, token, sizeof(token));
    issued.allowed_operation = operation_text;
    issued.allowed_scope     = scope_text;
    *capability              = issued;
    return true;
}

bool Authority::verify(const Capability &capability, const char *operation,
                       const char *scope) const {
    if (!capability.valid() || operation == 0 || scope == 0 ||
        capability.allowed_operation != operation || capability.allowed_scope != scope) {
        return false;
    }

    CapabilityGrantTable::const_iterator found = grants.find(token_key(capability.token));
    return found != grants.end() &&
           found->second.operation == capability.allowed_operation &&
           found->second.scope == capability.allowed_scope;
}

Size Authority::size() const {
    return grants.size();
}

bool Authority::encode(Value *value) const {
    if (value == 0 || grants.size() > MAX_GRANT_COUNT) {
        return false;
    }

    Bytes bytes;
    bytes.insert(bytes.end(), AUTHORITY_MAGIC, AUTHORITY_MAGIC + sizeof(AUTHORITY_MAGIC));
    write_u32(&bytes, CAPABILITY_VERSION);
    write_u32(&bytes, static_cast<U32>(grants.size()));
    for (CapabilityGrantTable::const_iterator grant = grants.begin(); grant != grants.end();
         ++grant) {
        if (grant->first.size() != Capability::TOKEN_SIZE ||
            !valid_name(grant->second.operation) || !valid_name(grant->second.scope)) {
            return false;
        }
        bytes.insert(bytes.end(), grant->first.begin(), grant->first.end());
        write_u32(&bytes, static_cast<U32>(grant->second.operation.size()));
        bytes.insert(bytes.end(), grant->second.operation.begin(),
                     grant->second.operation.end());
        write_u32(&bytes, static_cast<U32>(grant->second.scope.size()));
        bytes.insert(bytes.end(), grant->second.scope.begin(), grant->second.scope.end());
    }
    *value = Value(bytes);
    return true;
}

bool Authority::restore(const Value &value) {
    if (value.type() != VALUE_BYTES) {
        return false;
    }
    const Bytes &bytes = value.bytes();
    if (bytes.size() < CAPABILITY_MAGIC_SIZE + 8 ||
        memcmp(bytes.data(), AUTHORITY_MAGIC, sizeof(AUTHORITY_MAGIC)) != 0) {
        return false;
    }

    Size offset  = CAPABILITY_MAGIC_SIZE;
    U32  version = 0;
    U32  count   = 0;
    if (!read_u32(bytes, &offset, &version) || version != CAPABILITY_VERSION ||
        !read_u32(bytes, &offset, &count) || count > MAX_GRANT_COUNT) {
        return false;
    }

    CapabilityGrantTable restored;
    for (U32 i = 0; i < count; ++i) {
        if (offset > bytes.size() || bytes.size() - offset < Capability::TOKEN_SIZE) {
            return false;
        }
        const String key(reinterpret_cast<const char *>(bytes.data() + offset),
                         Capability::TOKEN_SIZE);
        offset += Capability::TOKEN_SIZE;
        CapabilityGrant grant;
        if (!read_string(bytes, &offset, &grant.operation) ||
            !read_string(bytes, &offset, &grant.scope) ||
            restored.find(key) != restored.end()) {
            return false;
        }
        restored[key] = grant;
    }
    if (offset != bytes.size()) {
        return false;
    }
    grants = restored;
    return true;
}

bool encode_capability(const Capability &capability, Value *value) {
    if (!capability.valid() || value == 0 ||
        capability.allowed_operation.size() > UINT32_MAX ||
        capability.allowed_scope.size() > UINT32_MAX) {
        return false;
    }

    Bytes bytes;
    bytes.insert(bytes.end(), CAPABILITY_MAGIC,
                 CAPABILITY_MAGIC + sizeof(CAPABILITY_MAGIC));
    write_u32(&bytes, CAPABILITY_VERSION);
    bytes.insert(bytes.end(), capability.token, capability.token + Capability::TOKEN_SIZE);
    write_u32(&bytes, static_cast<U32>(capability.allowed_operation.size()));
    bytes.insert(bytes.end(), capability.allowed_operation.begin(),
                 capability.allowed_operation.end());
    write_u32(&bytes, static_cast<U32>(capability.allowed_scope.size()));
    bytes.insert(bytes.end(), capability.allowed_scope.begin(),
                 capability.allowed_scope.end());
    *value = Value(bytes);
    return true;
}

bool decode_capability(const Value &value, Capability *capability) {
    if (value.type() != VALUE_BYTES || capability == 0) {
        return false;
    }

    const Bytes &bytes      = value.bytes();
    const Size   fixed_size = CAPABILITY_MAGIC_SIZE + 4 + Capability::TOKEN_SIZE + 4 + 4;
    if (bytes.size() < fixed_size ||
        memcmp(bytes.data(), CAPABILITY_MAGIC, sizeof(CAPABILITY_MAGIC)) != 0) {
        return false;
    }

    Size       offset  = CAPABILITY_MAGIC_SIZE;
    U32        version = 0;
    Capability decoded;
    if (!read_u32(bytes, &offset, &version) || version != CAPABILITY_VERSION ||
        bytes.size() - offset < Capability::TOKEN_SIZE) {
        return false;
    }
    memcpy(decoded.token, bytes.data() + offset, Capability::TOKEN_SIZE);
    offset += Capability::TOKEN_SIZE;
    if (!read_string(bytes, &offset, &decoded.allowed_operation) ||
        !read_string(bytes, &offset, &decoded.allowed_scope) || offset != bytes.size() ||
        !decoded.valid()) {
        return false;
    }
    *capability = decoded;
    return true;
}

} // namespace lucia
