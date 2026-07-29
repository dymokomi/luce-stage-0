#pragma once

#include "command.h"

namespace lucia {

class CommandSet;

// ---------------------------------------------------------------------------
// HelpCommand
// ---------------------------------------------------------------------------
//
// help — print the usage line of every command in the set.
//
class HelpCommand : public Command {
public:
    explicit HelpCommand(const CommandSet *command_set);

    const char *name() const override;
    Size        argument_count() const override;
    const char *usage() const override;

    CommandResult run(Store *store, const Strings &words) override;

private:
    const CommandSet *commands;
};

} // namespace lucia
