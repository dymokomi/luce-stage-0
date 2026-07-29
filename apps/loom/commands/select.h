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
        TexelId id;
        if (!resolve_texel(session->store, words[1], &id)) {
            return COMMAND_ERROR;
        }
        session->selected = id;
        printf("%s\n", id.format().c_str());
        return COMMAND_OK;
    }
};

} // namespace lucia
