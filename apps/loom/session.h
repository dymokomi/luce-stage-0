#pragma once

#include "fabric/persistence/store.h"
#include "loom/evaluation/spool.h"

namespace lucia {

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------
//
// Terminal state shared by commands: the open store, the evaluators the
// terminal offers, and the selected texel.  The selection is unset until
// select (or new) picks a texel to work on.
//
struct Session {
    Store                   *store;
    const EvaluatorRegistry *evaluators;
    TexelId                  selected;

    bool has_selection() const {
        return !selected.is_unset();
    }
};

} // namespace lucia
