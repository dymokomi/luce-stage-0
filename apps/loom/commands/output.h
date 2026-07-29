#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// OutputCommand
// ---------------------------------------------------------------------------
//
// output NAME TYPE — add a typed Output Port to the selected texel.
//
class OutputCommand : public Command {
public:
    const char *name() const override {
        return "output";
    }

    Size argument_count() const override {
        return 2;
    }

    const char *alias() const override {
        return "out";
    }

    const char *usage() const override {
        return "output NAME TYPE         (out) add an Output Port to the selected texel";
    }

    CommandResult run(Session *session, const Strings &words) override {
        Byte type = 0;
        if (!parse_type(words[2], &type)) {
            return COMMAND_ERROR;
        }
        if (!selected_exists(*session)) {
            return COMMAND_ERROR;
        }
        OutputInfo existing;
        if (find_output(session->store, session->selected, words[1], &existing)) {
            fprintf(stderr, "loom: output %s already exists\n", words[1].c_str());
            return COMMAND_ERROR;
        }
        Txn txn(session->store);
        if (!txn.ok() ||
            loom_txn_put_output(txn.get(), session->selected.bytes, words[1].c_str(),
                                type) != LOOM_OK ||
            !txn.commit()) {
            fprintf(stderr, "loom: output commit failed\n");
            return COMMAND_ERROR;
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
