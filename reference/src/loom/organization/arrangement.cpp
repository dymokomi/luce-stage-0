#include "loom/organization/arrangement.h"

#include <string.h>

namespace lucia {

namespace {

enum { HEADER_SIZE = 8, ENTRY_FIXED_SIZE = 1 + TexelId::SIZE, VERSION = 1 };

const Byte MAGIC[4] = {'L', 'A', 'R', 'R'};

typedef std::map<String, bool> ArrangementNames;

void put_u16(Bytes *bytes, Size value) {
    bytes->push_back(static_cast<Byte>(value & 0xffu));
    bytes->push_back(static_cast<Byte>((value >> 8) & 0xffu));
}

Size get_u16(const Byte *data) {
    return static_cast<Size>(data[0]) | (static_cast<Size>(data[1]) << 8);
}

bool valid_name(const String &name) {
    if (name.empty() || name.size() > ARRANGEMENT_MAX_NAME_SIZE) {
        return false;
    }
    return name.find('\0') == String::npos;
}

bool encode(const ArrangementEntries &entries, Bytes *output) {
    if (output == 0 || entries.size() > ARRANGEMENT_MAX_ENTRIES) {
        return false;
    }

    Size             encoded_size = HEADER_SIZE;
    ArrangementNames names;
    for (Size i = 0; i < entries.size(); ++i) {
        const ArrangementEntry &entry = entries[i];
        if (!valid_name(entry.name) || entry.texel.is_unset() ||
            names.find(entry.name) != names.end()) {
            return false;
        }
        names[entry.name] = true;
        encoded_size += ENTRY_FIXED_SIZE + entry.name.size();
        if (encoded_size > ARRANGEMENT_MAX_CONTENT_SIZE) {
            return false;
        }
    }

    Bytes encoded;
    encoded.reserve(encoded_size);
    encoded.insert(encoded.end(), MAGIC, MAGIC + sizeof(MAGIC));
    encoded.push_back(VERSION);
    encoded.push_back(0);
    put_u16(&encoded, entries.size());

    for (Size i = 0; i < entries.size(); ++i) {
        const ArrangementEntry &entry = entries[i];
        encoded.push_back(static_cast<Byte>(entry.name.size()));
        encoded.insert(encoded.end(), entry.name.begin(), entry.name.end());
        encoded.insert(encoded.end(), entry.texel.bytes(),
                       entry.texel.bytes() + TexelId::SIZE);
    }

    output->swap(encoded);
    return true;
}

bool decode(const Bytes &bytes, ArrangementEntries *output) {
    if (output == 0 || bytes.size() < HEADER_SIZE ||
        bytes.size() > ARRANGEMENT_MAX_CONTENT_SIZE ||
        memcmp(bytes.data(), MAGIC, sizeof(MAGIC)) != 0 || bytes[4] != VERSION ||
        bytes[5] != 0) {
        return false;
    }

    const Size entry_count = get_u16(bytes.data() + 6);
    if (entry_count > ARRANGEMENT_MAX_ENTRIES) {
        return false;
    }

    ArrangementEntries decoded;
    decoded.reserve(entry_count);
    ArrangementNames names;
    Size             offset = HEADER_SIZE;

    for (Size i = 0; i < entry_count; ++i) {
        if (offset >= bytes.size()) {
            return false;
        }
        const Size name_size = bytes[offset++];
        if (name_size == 0 || name_size > bytes.size() - offset ||
            bytes.size() - offset - name_size < TexelId::SIZE) {
            return false;
        }

        ArrangementEntry entry;
        entry.name.assign(reinterpret_cast<const char *>(bytes.data() + offset), name_size);
        offset += name_size;
        entry.texel.set_bytes(bytes.data() + offset);
        offset += TexelId::SIZE;

        if (!valid_name(entry.name) || entry.texel.is_unset() ||
            names.find(entry.name) != names.end()) {
            return false;
        }
        names[entry.name] = true;
        decoded.push_back(entry);
    }

    if (offset != bytes.size()) {
        return false;
    }
    output->swap(decoded);
    return true;
}

bool write(Texel *arrangement, const ArrangementEntries &entries) {
    if (arrangement == 0) {
        return false;
    }
    Bytes bytes;
    return encode(entries, &bytes) && arrangement->set_content(Value(bytes));
}

bool find_entry(const ArrangementEntries &entries, const char *name, Size *index) {
    if (name == 0 || index == 0) {
        return false;
    }
    for (Size i = 0; i < entries.size(); ++i) {
        if (entries[i].name == name) {
            *index = i;
            return true;
        }
    }
    return false;
}

} // namespace

bool create_arrangement(const TexelId &id, Texel *arrangement) {
    if (arrangement == 0 || id.is_unset()) {
        return false;
    }
    ArrangementEntries entries;
    Texel              created(id);
    if (!write(&created, entries)) {
        return false;
    }
    *arrangement = created;
    return true;
}

bool inspect_arrangement(const Texel &arrangement, ArrangementEntries *entries) {
    if (!arrangement.has_content() || arrangement.content().type() != VALUE_BYTES) {
        return false;
    }
    return decode(arrangement.content().bytes(), entries);
}

bool validate_arrangement(const Texel &arrangement, const Store &store) {
    ArrangementEntries entries;
    if (!inspect_arrangement(arrangement, &entries)) {
        return false;
    }
    for (Size i = 0; i < entries.size(); ++i) {
        if (!store.has(entries[i].texel)) {
            return false;
        }
    }
    return true;
}

bool arrangement_add(Texel *arrangement, const char *name, const TexelId &texel) {
    if (arrangement == 0 || name == 0 || texel.is_unset()) {
        return false;
    }
    ArrangementEntries entries;
    Size               ignored = 0;
    if (!inspect_arrangement(*arrangement, &entries) ||
        find_entry(entries, name, &ignored)) {
        return false;
    }
    ArrangementEntry entry;
    entry.name  = name;
    entry.texel = texel;
    entries.push_back(entry);
    return write(arrangement, entries);
}

bool arrangement_rename(Texel *arrangement, const char *name, const char *replacement) {
    if (arrangement == 0 || name == 0 || replacement == 0) {
        return false;
    }
    ArrangementEntries entries;
    Size               current = 0;
    if (!inspect_arrangement(*arrangement, &entries) ||
        !find_entry(entries, name, &current)) {
        return false;
    }
    Size duplicate = 0;
    if (find_entry(entries, replacement, &duplicate) && duplicate != current) {
        return false;
    }
    entries[current].name = replacement;
    return write(arrangement, entries);
}

bool arrangement_reorder(Texel *arrangement, const char *name, Size index) {
    if (arrangement == 0) {
        return false;
    }
    ArrangementEntries entries;
    Size               current = 0;
    if (!inspect_arrangement(*arrangement, &entries) || index >= entries.size() ||
        !find_entry(entries, name, &current)) {
        return false;
    }

    const ArrangementEntry moved = entries[current];
    entries.erase(entries.begin() + current);
    entries.insert(entries.begin() + index, moved);
    return write(arrangement, entries);
}

bool arrangement_remove(Texel *arrangement, const char *name) {
    if (arrangement == 0) {
        return false;
    }
    ArrangementEntries entries;
    Size               current = 0;
    if (!inspect_arrangement(*arrangement, &entries) ||
        !find_entry(entries, name, &current)) {
        return false;
    }
    entries.erase(entries.begin() + current);
    return write(arrangement, entries);
}

} // namespace lucia
