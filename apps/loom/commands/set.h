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
        if (!selected_exists(*session)) {
            return COMMAND_ERROR;
        }
        OutputInfo port;
        if (!find_output(session->store, session->selected, words[1], &port)) {
            fprintf(stderr, "loom: no output named %s\n", words[1].c_str());
            return COMMAND_ERROR;
        }
        ValueBox value;
        if (!parse_value(words[2], port.raw.type, &value)) {
            return COMMAND_ERROR;
        }
        Txn txn(session->store);
        if (!txn.ok() ||
            loom_txn_set_source(txn.get(), session->selected.bytes, words[1].c_str(),
                                &value.raw) != LOOM_OK ||
            !txn.commit()) {
            fprintf(stderr, "loom: set commit failed\n");
            return COMMAND_ERROR;
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
