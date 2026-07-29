#pragma once

#include "command.h"

namespace lucia {

// ---------------------------------------------------------------------------
// ListCommand
// ---------------------------------------------------------------------------
//
// list — print every texel with its name, or - when it has none.
//
class ListCommand : public Command {
public:
    const char *name() const override;
    Size        argument_count() const override;
    const char *usage() const override;

    CommandResult run(Store *store, const Strings &words) override;
};

} // namespace lucia
