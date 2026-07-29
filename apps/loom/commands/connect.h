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
// the source texel (an id or a unique name).  Port types must match; an
// Input Port holds at most one Fiber, so connecting again replaces the
// old binding.
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
        Id source;
        if (!resolve_texel(session->store, words[2], &source)) {
            return COMMAND_ERROR;
        }
        if (!selected_exists(*session)) {
            return COMMAND_ERROR;
        }
        Txn txn(session->store);
        if (!txn.ok() ||
            loom_txn_connect(txn.get(), session->selected.bytes, words[1].c_str(),
                             source.bytes, words[3].c_str()) != LOOM_OK ||
            !txn.commit()) {
            fprintf(stderr, "loom: connect failed (check both ports exist and "
                            "types match)\n");
            return COMMAND_ERROR;
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
