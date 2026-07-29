#pragma once

#include "command_set.h"
#include "evaluators.h"
#include "session.h"

namespace lucia {

// ---------------------------------------------------------------------------
// Terminal
// ---------------------------------------------------------------------------
//
// Interactive command loop over one open Fabric, entirely above the C
// border.  Reads one command per line, dispatches it through the command
// set, and reconciles after each: changes since the last seen generation
// expand through the fiber index into a dirty closure, the long-lived
// spool advances past clean records, and dirty watches are re-demanded.
// Push invalidates; pull evaluates.  The prompt appears only when
// standard input is a tty and shows the selected texel's name.
//
class Terminal {
public:
    explicit Terminal(loom_store *store);
    ~Terminal();

    int run();

private:
    Terminal(const Terminal &);
    Terminal &operator=(const Terminal &);

    void reconcile();

    Session      session;
    EvaluatorSet evaluators;
    CommandSet   commands;
    loom_spool  *spool;
    loom_index  *index;
    U64          seen;
};

} // namespace lucia
