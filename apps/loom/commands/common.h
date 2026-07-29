#pragma once

#include <stdio.h>

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

} // namespace lucia
