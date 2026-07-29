#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// PullCommand
// ---------------------------------------------------------------------------
//
// pull OUTPUT — demand the selected texel's output through a fresh Spool
// and print the outcome.  Demand pulls upstream values and runs evaluators
// only where cached revisions are stale.
//
class PullCommand : public Command {
public:
    const char *name() const override {
        return "pull";
    }

    Size argument_count() const override {
        return 1;
    }

    const char *alias() const override {
        return "p";
    }

    const char *usage() const override {
        return "pull OUTPUT              (p)   demand a selected output and print it";
    }

    CommandResult run(Session *session, const Strings &words) override {
        Texel texel;
        if (!selected_texel(*session, &texel)) {
            return COMMAND_ERROR;
        }
        Spool        spool(session->store, session->evaluators);
        ValueOutcome outcome;
        if (!spool.demand(session->selected, words[1].c_str(), &outcome)) {
            fprintf(stderr, "loom: demand failed (no output named %s?)\n",
                    words[1].c_str());
            return COMMAND_ERROR;
        }
        if (outcome.status() == VALUE_ERROR) {
            fprintf(stderr, "loom: %s\n", outcome.message().c_str());
            return COMMAND_ERROR;
        }
        if (outcome.status() == VALUE_UNAVAILABLE) {
            printf("unavailable\n");
            return COMMAND_OK;
        }
        printf("%s\n", value_text(outcome.value()).c_str());
        return COMMAND_OK;
    }
};

} // namespace lucia
