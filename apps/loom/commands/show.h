#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// ShowCommand
// ---------------------------------------------------------------------------
//
// show — print the selected texel: identity, name, and every typed port
// with its binding or source state.
//
class ShowCommand : public Command {
public:
    const char *name() const override {
        return "show";
    }

    Size argument_count() const override {
        return 0;
    }

    const char *alias() const override {
        return "sh";
    }

    const char *usage() const override {
        return "show                     (sh)  show the selected texel and its ports";
    }

    CommandResult run(Session *session, const Strings &) override {
        Texel texel;
        if (!selected_texel(*session, &texel)) {
            return COMMAND_ERROR;
        }
        String found;
        printf("id: %s\n", texel.id().format().c_str());
        printf("name: %s\n", texel_name(texel, &found) ? found.c_str() : "-");
        printf("revision: %llu\n", (unsigned long long)texel.revision());
        printf("evaluator: %s\n",
               texel.evaluator().empty() ? "-" : texel.evaluator().c_str());
        for (Size i = 0; i < texel.input_size(); ++i) {
            InputPort input;
            texel.input_at(i, &input);
            printf("input %s %s", input.name().c_str(), type_name(input.type()));
            if (input.has_binding()) {
                printf(" <- %s %s", input.binding().source().format().c_str(),
                       input.binding().output().c_str());
            }
            printf("\n");
        }
        for (Size i = 0; i < texel.output_size(); ++i) {
            OutputPort output;
            texel.output_at(i, &output);
            printf("output %s %s source=%s revision=%llu\n", output.name().c_str(),
                   type_name(output.type()), output.has_source() ? "yes" : "no",
                   (unsigned long long)output.revision());
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
