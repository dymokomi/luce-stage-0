#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// PullCommand
// ---------------------------------------------------------------------------
//
// pull OUTPUT — one-shot demand on the selected texel's output through
// the session spool.  Demand pulls upstream values and runs evaluators
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
        if (!selected_exists(*session)) {
            return COMMAND_ERROR;
        }
        Outcome outcome;
        if (loom_spool_demand(session->spool, session->selected.bytes, words[1].c_str(),
                              &outcome.raw) != LOOM_OK) {
            fprintf(stderr, "loom: demand failed\n");
            return COMMAND_ERROR;
        }
        if (outcome.raw.status == LOOM_OUTCOME_ERROR) {
            fprintf(stderr, "loom: %s\n", outcome_text(outcome.raw).c_str());
            return COMMAND_ERROR;
        }
        if (outcome.raw.status == LOOM_OUTCOME_UNAVAILABLE) {
            printf("unavailable\n");
            return COMMAND_OK;
        }
        printf("%s\n", value_text(outcome.raw.value).c_str());
        return COMMAND_OK;
    }
};

} // namespace lucia
