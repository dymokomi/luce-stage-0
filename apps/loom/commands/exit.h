#pragma once

#include "command.h"

namespace lucia {

// ---------------------------------------------------------------------------
// ExitCommand
// ---------------------------------------------------------------------------
//
// exit — leave the terminal.
//
class ExitCommand : public Command {
public:
    const char *name() const override {
        return "exit";
    }

    Size argument_count() const override {
        return 0;
    }

    const char *alias() const override {
        return "q";
    }

    const char *usage() const override {
        return "exit                     (q)   leave the terminal";
    }

    CommandResult run(Session *, const Strings &) override {
        return COMMAND_EXIT;
    }
};

} // namespace lucia
