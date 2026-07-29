#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// WatchCommand
// ---------------------------------------------------------------------------
//
// watch OUTPUT — event-activated demand: print the selected texel's output
// now, then again whenever a change moves its value.
//
class WatchCommand : public Command {
public:
    const char *name() const override {
        return "watch";
    }

    Size argument_count() const override {
        return 1;
    }

    const char *alias() const override {
        return "w";
    }

    const char *usage() const override {
        return "watch OUTPUT             (w)   print a selected output when it changes";
    }

    CommandResult run(Session *session, const Strings &words) override {
        if (!selected_exists(*session)) {
            return COMMAND_ERROR;
        }
        OutputInfo port;
        if (!find_output(session->store, session->selected, words[1], &port)) {
            fprintf(stderr, "loom: no output named %s\n", words[1].c_str());
            return COMMAND_ERROR;
        }
        for (WatchList::const_iterator watch = session->watches.begin();
             watch != session->watches.end(); ++watch) {
            if (watch->texel.equals(session->selected) && watch->output == words[1]) {
                fprintf(stderr, "loom: already watching %s\n", words[1].c_str());
                return COMMAND_ERROR;
            }
        }

        Watch   watch;
        Outcome outcome;
        watch.texel  = session->selected;
        watch.output = words[1];
        if (loom_spool_demand(session->spool, watch.texel.bytes, watch.output.c_str(),
                              &outcome.raw) != LOOM_OK) {
            fprintf(stderr, "loom: demand failed for %s\n", words[1].c_str());
            return COMMAND_ERROR;
        }
        watch.last = outcome_text(outcome.raw);
        print_outcome(session->store, watch.texel, watch.output, outcome.raw);
        session->watches.push_back(watch);
        return COMMAND_OK;
    }
};

} // namespace lucia
