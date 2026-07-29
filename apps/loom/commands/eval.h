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
        Evaluator *evaluator;
        if (!session->evaluators->get(words[1].c_str(), &evaluator)) {
            fprintf(stderr, "loom: unknown evaluator %s (%s)\n", words[1].c_str(),
                    EVALUATOR_NAMES);
            return COMMAND_ERROR;
        }
        Texel texel;
        if (!selected_texel(*session, &texel)) {
            return COMMAND_ERROR;
        }
        texel.set_evaluator(words[1].c_str());
        if (!commit_put(session->store, texel)) {
            fprintf(stderr, "loom: eval commit failed\n");
            return COMMAND_ERROR;
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
