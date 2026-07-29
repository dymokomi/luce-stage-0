#include "commands/common.h"

#include <stdio.h>

namespace lucia {

const char NAME_PORT[] = "name";

bool parse_id(const String &text, TexelId *id) {
    if (!id->parse(text.c_str()) || id->is_unset()) {
        fprintf(stderr, "loom: invalid texel id %s\n", text.c_str());
        return false;
    }
    return true;
}

bool texel_name(const Texel &texel, String *name) {
    OutputPort port;
    if (!texel.get_output(NAME_PORT, &port) || !port.has_source() ||
        port.source().type() != VALUE_TEXT) {
        return false;
    }
    *name = port.source().text();
    return true;
}

void set_name(Texel *texel, const String &name) {
    OutputPort port;
    if (!texel->get_output(NAME_PORT, &port)) {
        port = OutputPort(NAME_PORT, VALUE_TEXT);
    }
    port.set_source(Value(name));
    texel->put_output(port);
}

bool commit_put(Store *store, const Texel &texel) {
    Transaction transaction;
    return store->begin(&transaction) && transaction.put(texel) && transaction.commit();
}

} // namespace lucia
