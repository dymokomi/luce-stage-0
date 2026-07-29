#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// FindCommand
// ---------------------------------------------------------------------------
//
// find TEXT — list every texel whose name contains TEXT.
//
class FindCommand : public Command {
public:
    const char *name() const override {
        return "find";
    }

    Size argument_count() const override {
        return 1;
    }

    const char *alias() const override {
        return "f";
    }

    const char *usage() const override {
        return "find TEXT       (f)   list texels whose name contains TEXT";
    }

    CommandResult run(Store *store, const Strings &words) override {
        Size matches = 0;
        for (Size i = 0; i < store->size(); ++i) {
            Texel texel;
            if (!store->at(i, &texel)) {
                return COMMAND_ERROR;
            }
            String found;
            if (!texel_name(texel, &found) || found.find(words[1]) == String::npos) {
                continue;
            }
            printf("%s %s\n", texel.id().format().c_str(), found.c_str());
            ++matches;
        }
        if (matches == 0) {
            printf("no matches\n");
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
