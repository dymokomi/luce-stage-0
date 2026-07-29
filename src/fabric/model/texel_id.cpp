#include "fabric/model/texel_id.h"

#include <random>
#include <string.h>

namespace lucia {

namespace {

int hex_value(char character) {
    if (character >= '0' && character <= '9') {
        return character - '0';
    }
    if (character >= 'a' && character <= 'f') {
        return character - 'a' + 10;
    }
    if (character >= 'A' && character <= 'F') {
        return character - 'A' + 10;
    }
    return -1;
}

} // namespace

TexelId::TexelId() {
    memset(id_bytes, 0, SIZE);
}

bool TexelId::generate() {
    std::random_device random;

    for (Size i = 0; i < SIZE; ++i) {
        id_bytes[i] = static_cast<Byte>(random());
    }

    if (is_unset()) {
        id_bytes[SIZE - 1] = 1;
    }
    return true;
}

bool TexelId::parse(const char *text) {
    if (text == 0 || strlen(text) != TEXT_SIZE) {
        return false;
    }

    Byte parsed[SIZE];
    for (Size i = 0; i < SIZE; ++i) {
        const int high = hex_value(text[i * 2]);
        const int low  = hex_value(text[i * 2 + 1]);
        if (high < 0 || low < 0) {
            return false;
        }
        parsed[i] = static_cast<Byte>((high << 4) | low);
    }

    memcpy(id_bytes, parsed, SIZE);
    return true;
}

String TexelId::format() const {
    static const char hex[] = "0123456789abcdef";

    String text(TEXT_SIZE, '0');
    for (Size i = 0; i < SIZE; ++i) {
        text[i * 2]     = hex[id_bytes[i] >> 4];
        text[i * 2 + 1] = hex[id_bytes[i] & 0x0f];
    }
    return text;
}

bool TexelId::is_unset() const {
    for (Size i = 0; i < SIZE; ++i) {
        if (id_bytes[i] != 0) {
            return false;
        }
    }
    return true;
}

bool TexelId::equals(const TexelId &other) const {
    return memcmp(id_bytes, other.id_bytes, SIZE) == 0;
}

bool TexelId::less_than(const TexelId &other) const {
    return memcmp(id_bytes, other.id_bytes, SIZE) < 0;
}

const Byte *TexelId::bytes() const {
    return id_bytes;
}

void TexelId::set_bytes(const Byte *data) {
    if (data == 0) {
        memset(id_bytes, 0, SIZE);
        return;
    }
    memcpy(id_bytes, data, SIZE);
}

bool operator<(const TexelId &left, const TexelId &right) {
    return left.less_than(right);
}

} // namespace lucia
