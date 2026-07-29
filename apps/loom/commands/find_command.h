#pragma once

#include "command.h"

namespace lucia {

// ---------------------------------------------------------------------------
// FindCommand
// ---------------------------------------------------------------------------
//
// find TEXT — list every texel whose name contains TEXT.
//
class FindCommand : public Command {
public:
    const char *name() const override;
    Size        argument_count() const override;
    const char *usage() const override;

    CommandResult run(Store *store, const Strings &words) override;
};

} // namespace lucia
