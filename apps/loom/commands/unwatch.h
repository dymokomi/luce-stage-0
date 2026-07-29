#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// UnwatchCommand
// ---------------------------------------------------------------------------
//
// unwatch OUTPUT — stop watching an output on the selected texel.
//
class UnwatchCommand : public Command {
public:
    const char *name() const override {
        return "unwatch";
    }

    Size argument_count() const override {
        return 1;
    }

    const char *alias() const override {
        return "uw";
    }

    const char *usage() const override {
        return "unwatch OUTPUT           (uw)  stop watching a selected output";
    }

    CommandResult run(Session *session, const Strings &words) override {
        if (!session->has_selection()) {
            fprintf(stderr, "loom: no texel selected (try select ID)\n");
            return COMMAND_ERROR;
        }
        for (WatchList::iterator watch = session->watches.begin();
             watch != session->watches.end(); ++watch) {
            if (watch->texel.equals(session->selected) && watch->output == words[1]) {
                session->watches.erase(watch);
                return COMMAND_OK;
            }
        }
        fprintf(stderr, "loom: not watching %s\n", words[1].c_str());
        return COMMAND_ERROR;
    }
};

} // namespace lucia
