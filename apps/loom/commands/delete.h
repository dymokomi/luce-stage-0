#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// DeleteCommand
// ---------------------------------------------------------------------------
//
// delete ID — remove a texel; refused while other texels still reference it.
//
class DeleteCommand : public Command {
public:
    const char *name() const override {
        return "delete";
    }

    Size argument_count() const override {
        return 1;
    }

    const char *alias() const override {
        return "rm";
    }

    const char *usage() const override {
        return "delete ID       (rm)  remove a texel";
    }

    CommandResult run(Store *store, const Strings &words) override {
        TexelId id;
        if (!parse_id(words[1], &id)) {
            return COMMAND_ERROR;
        }
        if (!store->has(id)) {
            fprintf(stderr, "loom: texel not found\n");
            return COMMAND_ERROR;
        }
        Transaction transaction;
        if (!store->begin(&transaction) || !transaction.remove(id) ||
            !transaction.commit()) {
            fprintf(stderr, "loom: delete failed (texel is still connected)\n");
            return COMMAND_ERROR;
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
