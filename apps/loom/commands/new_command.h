#pragma once

#include "command.h"

namespace lucia {

// ---------------------------------------------------------------------------
// NewCommand
// ---------------------------------------------------------------------------
//
// new NAME — create a texel named NAME and print its id.
//
class NewCommand : public Command {
public:
    const char *name() const override;
    Size        argument_count() const override;
    const char *usage() const override;

    CommandResult run(Store *store, const Strings &words) override;
};

} // namespace lucia
