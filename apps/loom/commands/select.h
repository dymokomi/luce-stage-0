#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// SelectCommand
// ---------------------------------------------------------------------------
//
// select ID|NAME — make one texel active.  An argument that is not an id is
// looked up as an exact name; the match must be unique.
//
class SelectCommand : public Command {
public:
    const char *name() const override {
        return "select";
    }

    Size argument_count() const override {
        return 1;
    }

    const char *alias() const override {
        return "s";
    }

    const char *usage() const override {
        return "select ID|NAME           (s)   select the texel to work on";
    }

    CommandResult run(Session *session, const Strings &words) override {
        Store  *store = session->store;
        TexelId id;
        if (id.parse(words[1].c_str()) && !id.is_unset() && store->has(id)) {
            session->selected = id;
            printf("%s\n", id.format().c_str());
            return COMMAND_OK;
        }

        Size    matches = 0;
        TexelId found;
        for (Size i = 0; i < store->size(); ++i) {
            Texel texel;
            if (!store->at(i, &texel)) {
                return COMMAND_ERROR;
            }
            String name;
            if (texel_name(texel, &name) && name == words[1]) {
                found = texel.id();
                ++matches;
            }
        }
        if (matches == 0) {
            fprintf(stderr, "loom: no texel named %s\n", words[1].c_str());
            return COMMAND_ERROR;
        }
        if (matches > 1) {
            fprintf(stderr, "loom: %zu texels named %s (select by id)\n", matches,
                    words[1].c_str());
            return COMMAND_ERROR;
        }
        session->selected = found;
        printf("%s\n", found.format().c_str());
        return COMMAND_OK;
    }
};

} // namespace lucia
