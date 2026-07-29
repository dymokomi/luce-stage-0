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
        return "find TEXT                (f)   list texels whose name contains TEXT";
    }

    CommandResult run(Session *session, const Strings &words) override {
        Size       matches = 0;
        const Size count   = loom_store_count(session->store);
        for (Size i = 0; i < count; ++i) {
            Id id;
            if (loom_store_id_at(session->store, i, id.bytes) != LOOM_OK) {
                return COMMAND_ERROR;
            }
            String found;
            if (!texel_name(session->store, id, &found) ||
                found.find(words[1]) == String::npos) {
                continue;
            }
            printf("%s %s\n", id.format().c_str(), found.c_str());
            ++matches;
        }
        if (matches == 0) {
            printf("no matches\n");
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
