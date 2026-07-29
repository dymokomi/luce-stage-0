#pragma once

#include "fabric/persistence/store.h"

namespace lucia {

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------
//
// Terminal state shared by commands: the open store and the selected texel.
// The selection is unset until select (or new) picks a texel to work on.
//
struct Session {
    Store  *store;
    TexelId selected;

    bool has_selection() const {
        return !selected.is_unset();
    }
};

} // namespace lucia
