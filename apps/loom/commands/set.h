#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// SetCommand
// ---------------------------------------------------------------------------
//
// set NAME VALUE — set a source value on the selected texel's Output Port
// NAME, parsed against the port's declared type.
//
class SetCommand : public Command {
public:
    const char *name() const override {
        return "set";
    }

    Size argument_count() const override {
        return 2;
    }

    const char *alias() const override {
        return "se";
    }

    const char *usage() const override {
        return "set NAME VALUE           (se)  set a source value on a selected output";
    }

    CommandResult run(Session *session, const Strings &words) override {
        Texel texel;
        if (!selected_texel(*session, &texel)) {
            return COMMAND_ERROR;
        }
        OutputPort port;
        if (!texel.get_output(words[1].c_str(), &port)) {
            fprintf(stderr, "loom: no output named %s\n", words[1].c_str());
            return COMMAND_ERROR;
        }
        Value value;
        if (!parse_value(words[2], port.type(), &value)) {
            return COMMAND_ERROR;
        }
        port.set_source(value);
        texel.put_output(port);
        if (!commit_put(session->store, texel)) {
            fprintf(stderr, "loom: set commit failed\n");
            return COMMAND_ERROR;
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
