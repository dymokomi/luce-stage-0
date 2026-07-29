#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// InputCommand
// ---------------------------------------------------------------------------
//
// input NAME TYPE — add a typed Input Port to the selected texel.
//
class InputCommand : public Command {
public:
    const char *name() const override {
        return "input";
    }

    Size argument_count() const override {
        return 2;
    }

    const char *alias() const override {
        return "in";
    }

    const char *usage() const override {
        return "input NAME TYPE          (in)  add an Input Port to the selected texel";
    }

    CommandResult run(Session *session, const Strings &words) override {
        Byte type = 0;
        if (!parse_type(words[2], &type)) {
            return COMMAND_ERROR;
        }
        if (!selected_exists(*session)) {
            return COMMAND_ERROR;
        }
        InputInfo existing;
        if (find_input(session->store, session->selected, words[1], &existing)) {
            fprintf(stderr, "loom: input %s already exists\n", words[1].c_str());
            return COMMAND_ERROR;
        }
        Txn txn(session->store);
        if (!txn.ok() ||
            loom_txn_put_input(txn.get(), session->selected.bytes, words[1].c_str(),
                               type) != LOOM_OK ||
            !txn.commit()) {
            fprintf(stderr, "loom: input commit failed\n");
            return COMMAND_ERROR;
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
