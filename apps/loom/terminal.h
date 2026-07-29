#pragma once

#include "commands.h"

namespace lucia {

// ---------------------------------------------------------------------------
// Terminal
// ---------------------------------------------------------------------------
//
// Interactive command loop over one open Fabric.  Reads one command per
// line, dispatches it, and keeps going until exit or end of input.  The
// prompt appears only when standard input is a terminal.
//
class Terminal {
public:
    explicit Terminal(Store *store);

    int run();

private:
    Store *fabric;
};

} // namespace lucia
