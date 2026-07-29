#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// NewCommand
// ---------------------------------------------------------------------------
//
// new NAME — create a texel named NAME, select it, and print its id.
//
class NewCommand : public Command {
public:
    const char *name() const override {
        return "new";
    }

    Size argument_count() const override {
        return 1;
    }

    const char *alias() const override {
        return "n";
    }

    const char *usage() const override {
        return "new NAME                 (n)   create a texel, select it, and print its id";
    }

    CommandResult run(Session *session, const Strings &words) override {
        Id  id;
        Txn txn(session->store);
        if (!txn.ok() || loom_txn_create_texel(txn.get(), id.bytes) != LOOM_OK ||
            !set_name(txn.get(), id, words[1]) || !txn.commit()) {
            fprintf(stderr, "loom: new commit failed\n");
            return COMMAND_ERROR;
        }
        session->selected = id;
        printf("%s\n", id.format().c_str());
        return COMMAND_OK;
    }
};

} // namespace lucia
