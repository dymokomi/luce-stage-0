#pragma once

#include "command.h"

namespace lucia {

// ---------------------------------------------------------------------------
// RenameCommand
// ---------------------------------------------------------------------------
//
// rename ID NAME — give a texel a new name without touching its identity.
//
class RenameCommand : public Command {
public:
    const char *name() const override;
    Size        argument_count() const override;
    const char *usage() const override;

    CommandResult run(Store *store, const Strings &words) override;
};

} // namespace lucia
