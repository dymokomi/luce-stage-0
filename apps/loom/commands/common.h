#pragma once

#include <stdio.h>
#include <stdlib.h>

#include "base/types.h"
#include "session.h"

namespace lucia {

// A texel's name is ordinary Fabric material: a text value offered on the
// "name" Output Port.  Identity never depends on it.
inline const char NAME_PORT[] = "name";

// Parse id text typed in the terminal; reports an invalid id on stderr.
inline bool parse_id(const String &text, TexelId *id) {
    if (!id->parse(text.c_str()) || id->is_unset()) {
        fprintf(stderr, "loom: invalid texel id %s\n", text.c_str());
        return false;
    }
    return true;
}

// Parse a port type name; reports the valid names on stderr.
inline bool parse_type(const String &text, ValueType *type) {
    if (text == "bool") {
        *type = VALUE_BOOL;
    } else if (text == "int") {
        *type = VALUE_INT;
    } else if (text == "real") {
        *type = VALUE_REAL;
    } else if (text == "text") {
        *type = VALUE_TEXT;
    } else if (text == "bytes") {
        *type = VALUE_BYTES;
    } else if (text == "texel") {
        *type = VALUE_TEXEL;
    } else if (text == "blob") {
        *type = VALUE_BLOB;
    } else {
        fprintf(stderr, "loom: unknown type %s (bool int real text bytes texel blob)\n",
                text.c_str());
        return false;
    }
    return true;
}

inline const char *type_name(ValueType type) {
    switch (type) {
    case VALUE_BOOL:
        return "bool";
    case VALUE_INT:
        return "int";
    case VALUE_REAL:
        return "real";
    case VALUE_TEXT:
        return "text";
    case VALUE_BYTES:
        return "bytes";
    case VALUE_TEXEL:
        return "texel";
    case VALUE_BLOB:
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
inline bool parse_value(const String &text, ValueType type, Value *value) {
    char *end = 0;
    switch (type) {
    case VALUE_BOOL:
        if (text == "true" || text == "false") {
            *value = Value(text == "true");
            return true;
        }
        fprintf(stderr, "loom: bool value must be true or false\n");
        return false;
    case VALUE_INT: {
        const S64 number = strtoll(text.c_str(), &end, 10);
        if (end == text.c_str() || *end != 0) {
            fprintf(stderr, "loom: %s is not an int\n", text.c_str());
            return false;
        }
        *value = Value(number);
        return true;
    }
    case VALUE_REAL: {
        const double number = strtod(text.c_str(), &end);
        if (end == text.c_str() || *end != 0) {
            fprintf(stderr, "loom: %s is not a real\n", text.c_str());
            return false;
        }
        *value = Value(number);
        return true;
    }
    case VALUE_TEXT:
        *value = Value(text);
        return true;
    case VALUE_BYTES: {
        const Bytes bytes(text.begin(), text.end());
        *value = Value(bytes);
        return true;
    }
    case VALUE_TEXEL: {
        TexelId id;
        if (!id.parse(text.c_str()) || id.is_unset()) {
            fprintf(stderr, "loom: %s is not a texel id\n", text.c_str());
            return false;
        }
        *value = Value(id);
        return true;
    }
    default:
        fprintf(stderr, "loom: cannot set a %s value from the terminal\n",
                type == VALUE_BLOB ? "blob" : "none");
        return false;
    }
}

// Render a value for terminal display.
inline String value_text(const Value &value) {
    char buffer[64];
    switch (value.type()) {
    case VALUE_BOOL:
        return value.boolean() ? "true" : "false";
    case VALUE_INT:
        snprintf(buffer, sizeof(buffer), "%lld", (long long)value.integer());
        return buffer;
    case VALUE_REAL:
        snprintf(buffer, sizeof(buffer), "%g", value.real());
        return buffer;
    case VALUE_TEXT:
        return value.text();
    case VALUE_BYTES:
        snprintf(buffer, sizeof(buffer), "%zu bytes", value.bytes().size());
        return buffer;
    case VALUE_TEXEL:
        return value.texel().format();
    case VALUE_BLOB:
        return "blob";
    default:
        return "none";
    }
}

// Fetch the selected texel; reports a missing selection on stderr.
inline bool selected_texel(const Session &session, Texel *texel) {
    if (!session.has_selection()) {
        fprintf(stderr, "loom: no texel selected (try select ID)\n");
        return false;
    }
    if (!session.store->get(session.selected, texel)) {
        fprintf(stderr, "loom: selected texel no longer exists\n");
        return false;
    }
    return true;
}

// Read a texel's name; false when the texel offers no text name.
inline bool texel_name(const Texel &texel, String *name) {
    OutputPort port;
    if (!texel.get_output(NAME_PORT, &port) || !port.has_source() ||
        port.source().type() != VALUE_TEXT) {
        return false;
    }
    *name = port.source().text();
    return true;
}

// Resolve id-or-name text to a texel: valid id text wins, otherwise the
// argument must match exactly one texel's name.  Reports failures on stderr.
inline bool resolve_texel(const Store *store, const String &text, TexelId *id) {
    if (id->parse(text.c_str()) && !id->is_unset() && store->has(*id)) {
        return true;
    }
    Size    matches = 0;
    TexelId found;
    for (Size i = 0; i < store->size(); ++i) {
        Texel texel;
        if (!store->at(i, &texel)) {
            return false;
        }
        String name;
        if (texel_name(texel, &name) && name == text) {
            found = texel.id();
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

// Insert or replace the name Output Port with the given text.
inline void set_name(Texel *texel, const String &name) {
    OutputPort port;
    if (!texel->get_output(NAME_PORT, &port)) {
        port = OutputPort(NAME_PORT, VALUE_TEXT);
    }
    port.set_source(Value(name));
    texel->put_output(port);
}

// Put one texel in one committed transaction.
inline bool commit_put(Store *store, const Texel &texel) {
    Transaction transaction;
    return store->begin(&transaction) && transaction.put(texel) && transaction.commit();
}

// Short display label for a texel: its name, or the id's first characters.
inline String texel_label(const Store *store, const TexelId &id) {
    Texel  texel;
    String name;
    if (store->get(id, &texel) && texel_name(texel, &name)) {
        return name;
    }
    return id.format().substr(0, 8);
}

// True when two outcomes would display identically.
inline bool outcome_equals(const ValueOutcome &left, const ValueOutcome &right) {
    if (left.status() != right.status()) {
        return false;
    }
    if (left.status() == VALUE_AVAILABLE) {
        return left.value().equals(right.value());
    }
    if (left.status() == VALUE_ERROR) {
        return left.message() == right.message();
    }
    return true;
}

// Print one endpoint outcome as label.output = value.
inline void print_outcome(const Store *store, const TexelId &texel, const String &output,
                          const ValueOutcome &outcome) {
    const String label = texel_label(store, texel);
    if (outcome.status() == VALUE_ERROR) {
        printf("%s.%s error: %s\n", label.c_str(), output.c_str(),
               outcome.message().c_str());
    } else if (outcome.status() == VALUE_UNAVAILABLE) {
        printf("%s.%s unavailable\n", label.c_str(), output.c_str());
    } else {
        printf("%s.%s = %s\n", label.c_str(), output.c_str(),
               value_text(outcome.value()).c_str());
    }
}

} // namespace lucia
