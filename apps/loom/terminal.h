#pragma once

#include "command_set.h"
#include "evaluators.h"
#include "loom/evaluation/fiber_index.h"
#include "session.h"

namespace lucia {

// ---------------------------------------------------------------------------
// Terminal
// ---------------------------------------------------------------------------
//
// Interactive command loop over one open Fabric.  Reads one command per
// line, dispatches it through the command set, and reconciles after each:
// changes since the last seen generation expand through the FiberIndex
// into a dirty closure, the long-lived Spool advances past clean records,
// and dirty watches are re-demanded.  Push invalidates; pull evaluates.
// The prompt appears only when standard input is a tty and shows the
// selected texel's name.
//
class Terminal {
public:
    explicit Terminal(Store *store);

    int run();

private:
    void reconcile();

    Session      session;
    EvaluatorSet evaluators;
    CommandSet   commands;
    FiberIndex   index;
    Spool        spool;
    U64          seen;
};

} // namespace lucia
