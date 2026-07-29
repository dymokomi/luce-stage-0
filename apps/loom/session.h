#pragma once

#include <vector>

#include "fabric/persistence/store.h"
#include "loom/evaluation/spool.h"

namespace lucia {

// ---------------------------------------------------------------------------
// Watch
// ---------------------------------------------------------------------------
//
// One event-activated subscription: re-demand this endpoint after a change
// and print it when the outcome moves from the last one shown.
//
struct Watch {
    TexelId      texel;
    String       output;
    ValueOutcome last;
};

typedef std::vector<Watch> WatchList;

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------
//
// Terminal state shared by commands: the open store, the evaluators the
// terminal offers, the long-lived Spool the terminal reconciles, the watch
// list, and the selected texel.  The selection is unset until select (or
// new) picks a texel to work on.
//
struct Session {
    Store                   *store;
    const EvaluatorRegistry *evaluators;
    Spool                   *spool;
    TexelId                  selected;
    WatchList                watches;

    bool has_selection() const {
        return !selected.is_unset();
    }
};

} // namespace lucia
