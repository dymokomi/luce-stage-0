#pragma once

#include "command_set.h"

namespace lucia {

// ---------------------------------------------------------------------------
// Terminal
// ---------------------------------------------------------------------------
//
// Interactive command loop over one open Fabric.  Reads one command per
// line, dispatches it through the command set, and keeps going until exit
// or end of input.  The prompt appears only when standard input is a tty.
//
class Terminal {
public:
    explicit Terminal(Store *store);

    int run();

private:
    Store     *fabric;
    CommandSet commands;
};

} // namespace lucia
