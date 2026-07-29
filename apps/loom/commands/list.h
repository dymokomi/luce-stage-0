#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// ListCommand
// ---------------------------------------------------------------------------
//
// list — print every texel with its name, or - when it has none.  The
// selected texel is marked with a star.
//
class ListCommand : public Command {
public:
    const char *name() const override {
        return "list";
    }

    Size argument_count() const override {
        return 0;
    }

    const char *alias() const override {
        return "ls";
    }

    const char *usage() const override {
        return "list                     (ls)  list every texel";
    }

    CommandResult run(Session *session, const Strings &) override {
        const Size count = loom_store_count(session->store);
        for (Size i = 0; i < count; ++i) {
            Id id;
            if (loom_store_id_at(session->store, i, id.bytes) != LOOM_OK) {
                return COMMAND_ERROR;
            }
            String     found;
            const bool named    = texel_name(session->store, id, &found);
            const bool selected = id.equals(session->selected);
            printf("%s %s%s\n", id.format().c_str(), named ? found.c_str() : "-",
                   selected ? " *" : "");
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
