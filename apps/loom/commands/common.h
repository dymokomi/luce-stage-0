#pragma once

#include <stdio.h>
#include <stdlib.h>

#include "session.h"

namespace lucia {

// A texel's name is ordinary Fabric material: a text value offered on the
// "name" Output Port.  Identity never depends on it.
inline const char NAME_PORT[] = "name";

// Parse id text typed in the terminal; reports an invalid id on stderr.
inline bool parse_id(const String &text, Id *id) {
    if (!id->parse(text.c_str()) || id->is_unset()) {
        fprintf(stderr, "loom: invalid texel id %s\n", text.c_str());
        return false;
    }
    return true;
}

// Parse a port type name; reports the valid names on stderr.
inline bool parse_type(const String &text, Byte *type) {
    if (text == "bool") {
        *type = LOOM_VALUE_BOOL;
    } else if (text == "int") {
        *type = LOOM_VALUE_INT;
    } else if (text == "real") {
        *type = LOOM_VALUE_REAL;
    } else if (text == "text") {
        *type = LOOM_VALUE_TEXT;
    } else if (text == "bytes") {
        *type = LOOM_VALUE_BYTES;
    } else if (text == "texel") {
        *type = LOOM_VALUE_TEXEL;
    } else if (text == "blob") {
        *type = LOOM_VALUE_BLOB;
    } else {
        fprintf(stderr, "loom: unknown type %s (bool int real text bytes texel blob)\n",
                text.c_str());
        return false;
    }
    return true;
}

inline const char *type_name(Byte type) {
    switch (type) {
    case LOOM_VALUE_BOOL:
        return "bool";
    case LOOM_VALUE_INT:
        return "int";
    case LOOM_VALUE_REAL:
        return "real";
    case LOOM_VALUE_TEXT:
        return "text";
    case LOOM_VALUE_BYTES:
        return "bytes";
    case LOOM_VALUE_TEXEL:
        return "texel";
    case LOOM_VALUE_BLOB:
        return "blob";
    default:
        return "none";
    }
}

// Parse a port direction; reports the valid directions on stderr.
inline bool parse_direction(const String &text, bool *is_input) {
    if (text == "in") {
        *is_input = true;
        return true;
    }
    if (text == "out") {
        *is_input = false;
        return true;
    }
    fprintf(stderr, "loom: direction must be in or out\n");
    return false;
}

// Parse literal value text against a port's declared type; reports the
// failure on stderr.  Blobs cannot be written from the terminal.
inline bool parse_value(const String &text, Byte type, ValueBox *value) {
    char *end = 0;
    switch (type) {
    case LOOM_VALUE_BOOL:
        if (text == "true" || text == "false") {
            value->set_bool(text == "true");
            return true;
        }
        fprintf(stderr, "loom: bool value must be true or false\n");
        return false;
    case LOOM_VALUE_INT: {
        const S64 number = strtoll(text.c_str(), &end, 10);
        if (end == text.c_str() || *end != 0) {
            fprintf(stderr, "loom: %s is not an int\n", text.c_str());
            return false;
        }
        value->set_int(number);
        return true;
    }
    case LOOM_VALUE_REAL: {
        const double number = strtod(text.c_str(), &end);
        if (end == text.c_str() || *end != 0) {
            fprintf(stderr, "loom: %s is not a real\n", text.c_str());
            return false;
        }
        value->set_real(number);
        return true;
    }
    case LOOM_VALUE_TEXT:
        value->set_text(text);
        return true;
    case LOOM_VALUE_BYTES:
        value->set_bytes(text);
        return true;
    case LOOM_VALUE_TEXEL: {
        Id id;
        if (!id.parse(text.c_str()) || id.is_unset()) {
            fprintf(stderr, "loom: %s is not a texel id\n", text.c_str());
            return false;
        }
        value->set_texel(id);
        return true;
    }
    default:
        fprintf(stderr, "loom: cannot set a %s value from the terminal\n",
                type == LOOM_VALUE_BLOB ? "blob" : "none");
        return false;
    }
}

// Render a value for terminal display.
inline String value_text(const loom_value &value) {
    char buffer[64];
    switch (value.tag) {
    case LOOM_VALUE_BOOL:
        return value.boolean ? "true" : "false";
    case LOOM_VALUE_INT:
        snprintf(buffer, sizeof(buffer), "%lld", (long long)value.integer);
        return buffer;
    case LOOM_VALUE_REAL:
        snprintf(buffer, sizeof(buffer), "%g", value.real);
        return buffer;
    case LOOM_VALUE_TEXT:
        return value.data.data == 0
                   ? String()
                   : String(reinterpret_cast<const char *>(value.data.data),
                            value.data.size);
    case LOOM_VALUE_BYTES:
        snprintf(buffer, sizeof(buffer), "%zu bytes", value.data.size);
        return buffer;
    case LOOM_VALUE_TEXEL: {
        Id id;
        memcpy(id.bytes, value.texel, LOOM_ID_SIZE);
        return id.format();
    }
    case LOOM_VALUE_BLOB:
        return "blob";
    default:
        return "none";
    }
}

// Render an outcome the way watch and pull display it.
inline String outcome_text(const loom_outcome &outcome) {
    if (outcome.status == LOOM_OUTCOME_ERROR) {
        String message =
            outcome.error_message.data == 0
                ? String()
                : String(reinterpret_cast<const char *>(outcome.error_message.data),
                         outcome.error_message.size);
        return "error: " + message;
    }
    if (outcome.status == LOOM_OUTCOME_UNAVAILABLE) {
        return "unavailable";
    }
    return "= " + value_text(outcome.value);
}

// Reports a missing selection on stderr.
inline bool selected_exists(const Session &session) {
    if (!session.has_selection()) {
        fprintf(stderr, "loom: no texel selected (try select ID)\n");
        return false;
    }
    if (!loom_store_has(session.store, session.selected.bytes)) {
        fprintf(stderr, "loom: selected texel no longer exists\n");
        return false;
    }
    return true;
}

// Find a named output on a texel; true fills info.
inline bool find_output(const loom_store *store, const Id &id, const String &name,
                        OutputInfo *info) {
    Size count = 0;
    if (loom_texel_output_count(store, id.bytes, &count) != LOOM_OK) {
        return false;
    }
    for (Size i = 0; i < count; ++i) {
        info->reset();
        if (loom_texel_output_at(store, id.bytes, i, &info->raw) != LOOM_OK) {
            return false;
        }
        if (info->name() == name) {
            return true;
        }
    }
    return false;
}

inline bool find_input(const loom_store *store, const Id &id, const String &name,
                       InputInfo *info) {
    Size count = 0;
    if (loom_texel_input_count(store, id.bytes, &count) != LOOM_OK) {
        return false;
    }
    for (Size i = 0; i < count; ++i) {
        info->reset();
        if (loom_texel_input_at(store, id.bytes, i, &info->raw) != LOOM_OK) {
            return false;
        }
        if (info->name() == name) {
            return true;
        }
    }
    return false;
}

// Read a texel's name; false when the texel offers no text name.
inline bool texel_name(const loom_store *store, const Id &id, String *name) {
    OutputInfo info;
    if (!find_output(store, id, NAME_PORT, &info) || !info.raw.has_source ||
        info.raw.source.tag != LOOM_VALUE_TEXT) {
        return false;
    }
    *name = value_text(info.raw.source);
    return true;
}

// Resolve id-or-name text to a texel: valid id text wins, otherwise the
// argument must match exactly one texel's name.  Reports failures on stderr.
inline bool resolve_texel(const loom_store *store, const String &text, Id *id) {
    if (id->parse(text.c_str()) && !id->is_unset() && loom_store_has(store, id->bytes)) {
        return true;
    }
    Size       matches = 0;
    Id         found;
    const Size count = loom_store_count(store);
    for (Size i = 0; i < count; ++i) {
        Id candidate;
        if (loom_store_id_at(store, i, candidate.bytes) != LOOM_OK) {
            return false;
        }
        String name;
        if (texel_name(store, candidate, &name) && name == text) {
            found = candidate;
            ++matches;
        }
    }
    if (matches == 1) {
        *id = found;
        return true;
    }
    if (matches == 0) {
        fprintf(stderr, "loom: no texel named %s\n", text.c_str());
    } else {
        fprintf(stderr, "loom: %zu texels named %s (use the id)\n", matches, text.c_str());
    }
    return false;
}

// Give the texel its name value inside an open transaction.
inline bool set_name(loom_txn *txn, const Id &id, const String &name) {
    ValueBox value;
    value.set_text(name);
    return loom_txn_put_output(txn, id.bytes, NAME_PORT, LOOM_VALUE_TEXT) == LOOM_OK &&
           loom_txn_set_source(txn, id.bytes, NAME_PORT, &value.raw) == LOOM_OK;
}

// Short display label for a texel: its name, or the id's first characters.
inline String texel_label(const loom_store *store, const Id &id) {
    String name;
    if (texel_name(store, id, &name)) {
        return name;
    }
    return id.format().substr(0, 8);
}

// Print one endpoint outcome as label.output = value.
inline void print_outcome(const loom_store *store, const Id &texel, const String &output,
                          const loom_outcome &outcome) {
    printf("%s.%s %s\n", texel_label(store, texel).c_str(), output.c_str(),
           outcome_text(outcome).c_str());
}

} // namespace lucia
