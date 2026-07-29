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
        if (!selected_exists(*session)) {
            return COMMAND_ERROR;
        }
        const loom_store *store = session->store;
        const Id         &id    = session->selected;

        String found;
        U64    revision = 0;
        loom_texel_revision(store, id.bytes, &revision);
        printf("id: %s\n", id.format().c_str());
        printf("name: %s\n", texel_name(store, id, &found) ? found.c_str() : "-");
        printf("revision: %llu\n", (unsigned long long)revision);

        loom_buffer evaluator;
        if (loom_texel_evaluator(store, id.bytes, &evaluator) == LOOM_OK) {
            printf(
                "evaluator: %s\n",
                evaluator.size == 0
                    ? "-"
                    : String(reinterpret_cast<const char *>(evaluator.data), evaluator.size)
                          .c_str());
            loom_buffer_free(evaluator);
        }

        Size inputs = 0;
        loom_texel_input_count(store, id.bytes, &inputs);
        for (Size i = 0; i < inputs; ++i) {
            InputInfo info;
            if (loom_texel_input_at(store, id.bytes, i, &info.raw) != LOOM_OK) {
                return COMMAND_ERROR;
            }
            printf("input %s %s", info.name().c_str(), type_name(info.raw.type));
            if (info.raw.bound) {
                printf(" <- %s %s", info.source().format().c_str(),
                       info.source_output().c_str());
            }
            printf("\n");
        }

        Size outputs = 0;
        loom_texel_output_count(store, id.bytes, &outputs);
        for (Size i = 0; i < outputs; ++i) {
            OutputInfo info;
            if (loom_texel_output_at(store, id.bytes, i, &info.raw) != LOOM_OK) {
                return COMMAND_ERROR;
            }
            printf("output %s %s source=%s revision=%llu\n", info.name().c_str(),
                   type_name(info.raw.type), info.raw.has_source ? "yes" : "no",
                   (unsigned long long)info.raw.revision);
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
