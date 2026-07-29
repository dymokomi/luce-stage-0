#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// RenameCommand
// ---------------------------------------------------------------------------
//
// rename ID NAME — give a texel a new name without touching its identity.
//
class RenameCommand : public Command {
public:
    const char *name() const override {
        return "rename";
    }

    Size argument_count() const override {
        return 2;
    }

    const char *alias() const override {
        return "rn";
    }

    const char *usage() const override {
        return "rename ID NAME  (rn)  give a texel a new name";
    }

    CommandResult run(Store *store, const Strings &words) override {
        TexelId id;
        if (!parse_id(words[1], &id)) {
            return COMMAND_ERROR;
        }
        Texel texel;
        if (!store->get(id, &texel)) {
            fprintf(stderr, "loom: texel not found\n");
            return COMMAND_ERROR;
        }
        set_name(&texel, words[2]);
        if (!commit_put(store, texel)) {
            fprintf(stderr, "loom: rename commit failed\n");
            return COMMAND_ERROR;
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
