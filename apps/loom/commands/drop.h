#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// DropCommand
// ---------------------------------------------------------------------------
//
// drop DIR NAME — remove a port from the selected texel.  An Output Port
// with Fibers still bound to it is refused; disconnect the consumers first.
//
class DropCommand : public Command {
public:
    const char *name() const override {
        return "drop";
    }

    Size argument_count() const override {
        return 2;
    }

    const char *alias() const override {
        return "dr";
    }

    const char *usage() const override {
        return "drop DIR NAME            (dr)  remove a port from the selected texel";
    }

    CommandResult run(Session *session, const Strings &words) override {
        bool is_input;
        if (!parse_direction(words[1], &is_input)) {
            return COMMAND_ERROR;
        }
        Texel texel;
        if (!selected_texel(*session, &texel)) {
            return COMMAND_ERROR;
        }
        const String &port_name = words[2];
        if (is_input) {
            if (!texel.remove_input(port_name.c_str())) {
                fprintf(stderr, "loom: no input named %s\n", port_name.c_str());
                return COMMAND_ERROR;
            }
        } else {
            if (!texel.has_output(port_name.c_str())) {
                fprintf(stderr, "loom: no output named %s\n", port_name.c_str());
                return COMMAND_ERROR;
            }
            if (output_connected(session->store, texel.id(), port_name)) {
                fprintf(stderr, "loom: output %s is still connected\n", port_name.c_str());
                return COMMAND_ERROR;
            }
            texel.remove_output(port_name.c_str());
        }
        if (!commit_put(session->store, texel)) {
            fprintf(stderr, "loom: drop commit failed\n");
            return COMMAND_ERROR;
        }
        return COMMAND_OK;
    }

private:
    // True when any Input Port in the Fabric is bound to this output.
    static bool output_connected(const Store *store, const TexelId &id,
                                 const String &output_name) {
        for (Size i = 0; i < store->size(); ++i) {
            Texel texel;
            if (!store->at(i, &texel)) {
                continue;
            }
            for (Size j = 0; j < texel.input_size(); ++j) {
                InputPort input;
                texel.input_at(j, &input);
                if (input.has_binding() && input.binding().source().equals(id) &&
                    input.binding().output() == output_name) {
                    return true;
                }
            }
        }
        return false;
    }
};

} // namespace lucia
