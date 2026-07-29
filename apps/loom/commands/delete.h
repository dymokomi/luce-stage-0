#pragma once

#include "command.h"

namespace lucia {

// ---------------------------------------------------------------------------
// DeleteCommand
// ---------------------------------------------------------------------------
//
// delete ID — remove a texel; refused while other texels still reference it.
//
class DeleteCommand : public Command {
public:
    const char *name() const override;
    Size        argument_count() const override;
    const char *usage() const override;

    CommandResult run(Store *store, const Strings &words) override;
};

} // namespace lucia
