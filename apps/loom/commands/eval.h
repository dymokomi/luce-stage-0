#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"
#include "evaluators.h"

namespace lucia {

// ---------------------------------------------------------------------------
// EvalCommand
// ---------------------------------------------------------------------------
//
// eval NAME — assign a persisted evaluator to the selected texel.  The
// name must be one the terminal's registry actually offers.
//
class EvalCommand : public Command {
public:
    const char *name() const override {
        return "eval";
    }

    Size argument_count() const override {
        return 1;
    }

    const char *alias() const override {
        return "e";
    }

    const char *usage() const override {
        return "eval NAME                (e)   set the selected texel's evaluator";
    }

    CommandResult run(Session *session, const Strings &words) override {
        if (!known_evaluator(words[1])) {
            fprintf(stderr, "loom: unknown evaluator %s (%s)\n", words[1].c_str(),
                    EVALUATOR_NAMES);
            return COMMAND_ERROR;
        }
        if (!selected_exists(*session)) {
            return COMMAND_ERROR;
        }
        Txn txn(session->store);
        if (!txn.ok() ||
            loom_txn_set_evaluator(txn.get(), session->selected.bytes, words[1].c_str()) !=
                LOOM_OK ||
            !txn.commit()) {
            fprintf(stderr, "loom: eval commit failed\n");
            return COMMAND_ERROR;
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
