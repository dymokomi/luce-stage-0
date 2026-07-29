#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// ConnectCommand
// ---------------------------------------------------------------------------
//
// connect INPUT ID OUTPUT — bind the selected texel's INPUT to OUTPUT on
// the source texel ID.  Port types must match; an Input Port holds at most
// one Fiber, so connecting again replaces the old binding.
//
class ConnectCommand : public Command {
public:
    const char *name() const override {
        return "connect";
    }

    Size argument_count() const override {
        return 3;
    }

    const char *alias() const override {
        return "c";
    }

    const char *usage() const override {
        return "connect INPUT ID OUTPUT  (c)   bind a selected input to a source output";
    }

    CommandResult run(Session *session, const Strings &words) override {
        TexelId source;
        if (!parse_id(words[2], &source)) {
            return COMMAND_ERROR;
        }
        Texel texel;
        if (!selected_texel(*session, &texel)) {
            return COMMAND_ERROR;
        }
        Transaction transaction;
        if (!session->store->begin(&transaction) ||
            !transaction.connect(session->selected, words[1].c_str(), source,
                                 words[3].c_str()) ||
            !transaction.commit()) {
            fprintf(stderr, "loom: connect failed (check both ports exist and "
                            "types match)\n");
            return COMMAND_ERROR;
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
