#pragma once

#include <vector>

#include "engine.h"

namespace lucia {

// ---------------------------------------------------------------------------
// Watch
// ---------------------------------------------------------------------------
//
// One event-activated subscription: re-demand this endpoint after a change
// and print it when its rendered outcome moves from the last one shown.
//
struct Watch {
    Id     texel;
    String output;
    String last;
};

typedef std::vector<Watch> WatchList;

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------
//
// Terminal state shared by commands: the open store and spool handles
// (borrowed from the Terminal, which owns them), the watch list, and the
// selected texel.  The selection is unset until select (or new) picks a
// texel to work on.
//
struct Session {
    loom_store *store;
    loom_spool *spool;
    Id          selected;
    WatchList   watches;

    bool has_selection() const {
        return !selected.is_unset();
    }
};

} // namespace lucia
