#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// DisconnectCommand
// ---------------------------------------------------------------------------
//
// disconnect INPUT — unbind the Fiber on the selected texel's INPUT.
//
class DisconnectCommand : public Command {
public:
    const char *name() const override {
        return "disconnect";
    }

    Size argument_count() const override {
        return 1;
    }

    const char *alias() const override {
        return "dc";
    }

    const char *usage() const override {
        return "disconnect INPUT         (dc)  unbind an input on the selected texel";
    }

    CommandResult run(Session *session, const Strings &words) override {
        if (!selected_exists(*session)) {
            return COMMAND_ERROR;
        }
        Txn txn(session->store);
        if (!txn.ok() ||
            loom_txn_disconnect(txn.get(), session->selected.bytes, words[1].c_str()) !=
                LOOM_OK ||
            !txn.commit()) {
            fprintf(stderr, "loom: disconnect failed (no bound input named %s)\n",
                    words[1].c_str());
            return COMMAND_ERROR;
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
