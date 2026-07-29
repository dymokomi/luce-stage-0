#pragma once

#include "base/types.h"
#include "fabric/persistence/store.h"

namespace lucia {

// A texel's name is ordinary Fabric material: a text value offered on the
// "name" Output Port.  Identity never depends on it.
extern const char NAME_PORT[];

// Parse id text typed in the terminal; reports an invalid id on stderr.
bool parse_id(const String &text, TexelId *id);

// Read a texel's name; false when the texel offers no text name.
bool texel_name(const Texel &texel, String *name);

// Insert or replace the name Output Port with the given text.
void set_name(Texel *texel, const String &name);

// Put one texel in one committed transaction.
bool commit_put(Store *store, const Texel &texel);

} // namespace lucia
