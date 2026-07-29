#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// InputCommand
// ---------------------------------------------------------------------------
//
// input NAME TYPE — add a typed Input Port to the selected texel.
//
class InputCommand : public Command {
public:
    const char *name() const override {
        return "input";
    }

    Size argument_count() const override {
        return 2;
    }

    const char *alias() const override {
        return "in";
    }

    const char *usage() const override {
        return "input NAME TYPE          (in)  add an Input Port to the selected texel";
    }

    CommandResult run(Session *session, const Strings &words) override {
        ValueType type;
        if (!parse_type(words[2], &type)) {
            return COMMAND_ERROR;
        }
        Texel texel;
        if (!selected_texel(*session, &texel)) {
            return COMMAND_ERROR;
        }
        if (texel.has_input(words[1].c_str())) {
            fprintf(stderr, "loom: input %s already exists\n", words[1].c_str());
            return COMMAND_ERROR;
        }
        texel.put_input(InputPort(words[1].c_str(), type));
        if (!commit_put(session->store, texel)) {
            fprintf(stderr, "loom: input commit failed\n");
            return COMMAND_ERROR;
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
