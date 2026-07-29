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
    const char *name() const override;
    Size        argument_count() const override;
    const char *usage() const override;

    CommandResult run(Store *store, const Strings &words) override;
};

} // namespace lucia
