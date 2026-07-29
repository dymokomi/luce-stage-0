#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// RenameCommand
// ---------------------------------------------------------------------------
//
// rename NAME — give the selected texel a new name; identity is untouched.
//
class RenameCommand : public Command {
public:
    const char *name() const override {
        return "rename";
    }

    Size argument_count() const override {
        return 1;
    }

    const char *alias() const override {
        return "rn";
    }

    const char *usage() const override {
        return "rename NAME              (rn)  rename the selected texel";
    }

    CommandResult run(Session *session, const Strings &words) override {
        if (!selected_exists(*session)) {
            return COMMAND_ERROR;
        }
        Txn txn(session->store);
        if (!txn.ok() || !set_name(txn.get(), session->selected, words[1]) ||
            !txn.commit()) {
            fprintf(stderr, "loom: rename commit failed\n");
            return COMMAND_ERROR;
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
