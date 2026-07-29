#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// OutputCommand
// ---------------------------------------------------------------------------
//
// output NAME TYPE — add a typed Output Port to the selected texel.
//
class OutputCommand : public Command {
public:
    const char *name() const override {
        return "output";
    }

    Size argument_count() const override {
        return 2;
    }

    const char *alias() const override {
        return "out";
    }

    const char *usage() const override {
        return "output NAME TYPE         (out) add an Output Port to the selected texel";
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
        if (texel.has_output(words[1].c_str())) {
            fprintf(stderr, "loom: output %s already exists\n", words[1].c_str());
            return COMMAND_ERROR;
        }
        texel.put_output(OutputPort(words[1].c_str(), type));
        if (!commit_put(session->store, texel)) {
            fprintf(stderr, "loom: output commit failed\n");
            return COMMAND_ERROR;
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
