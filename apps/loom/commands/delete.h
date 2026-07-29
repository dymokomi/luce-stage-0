#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// DeleteCommand
// ---------------------------------------------------------------------------
//
// delete — remove the selected texel; refused while other texels still
// reference it.  A successful delete clears the selection.
//
class DeleteCommand : public Command {
public:
    const char *name() const override {
        return "delete";
    }

    Size argument_count() const override {
        return 0;
    }

    const char *alias() const override {
        return "rm";
    }

    const char *usage() const override {
        return "delete                   (rm)  delete the selected texel";
    }

    CommandResult run(Session *session, const Strings &) override {
        if (!selected_exists(*session)) {
            return COMMAND_ERROR;
        }
        Txn txn(session->store);
        if (!txn.ok() ||
            loom_txn_remove_texel(txn.get(), session->selected.bytes) != LOOM_OK ||
            !txn.commit()) {
            fprintf(stderr, "loom: delete failed (texel is still connected)\n");
            return COMMAND_ERROR;
        }
        session->selected = Id();
        return COMMAND_OK;
    }
};

} // namespace lucia
