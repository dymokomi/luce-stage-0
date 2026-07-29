#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// ListCommand
// ---------------------------------------------------------------------------
//
// list — print every texel with its name, or - when it has none.
//
class ListCommand : public Command {
public:
    const char *name() const override {
        return "list";
    }

    Size argument_count() const override {
        return 0;
    }

    const char *usage() const override {
        return "list           list every texel";
    }

    CommandResult run(Store *store, const Strings &) override {
        for (Size i = 0; i < store->size(); ++i) {
            Texel texel;
            if (!store->at(i, &texel)) {
                return COMMAND_ERROR;
            }
            String     found;
            const bool named = texel_name(texel, &found);
            printf("%s %s\n", texel.id().format().c_str(), named ? found.c_str() : "-");
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
