#pragma once

#include <stdio.h>

#include "base/types.h"
#include "fabric/persistence/store.h"

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
