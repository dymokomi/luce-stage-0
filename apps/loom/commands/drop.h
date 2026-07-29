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
        if (!selected_exists(*session)) {
            return COMMAND_ERROR;
        }
        const String &port_name = words[2];
        const Id     &id        = session->selected;

        if (is_input) {
            InputInfo info;
            if (!find_input(session->store, id, port_name, &info)) {
                fprintf(stderr, "loom: no input named %s\n", port_name.c_str());
                return COMMAND_ERROR;
            }
        } else {
            OutputInfo info;
            if (!find_output(session->store, id, port_name, &info)) {
                fprintf(stderr, "loom: no output named %s\n", port_name.c_str());
                return COMMAND_ERROR;
            }
            if (output_connected(session->store, id, port_name)) {
                fprintf(stderr, "loom: output %s is still connected\n", port_name.c_str());
                return COMMAND_ERROR;
            }
        }

        Txn               txn(session->store);
        const loom_status removed =
            !txn.ok()  ? LOOM_ERR_ARGUMENT
            : is_input ? loom_txn_remove_input(txn.get(), id.bytes, port_name.c_str())
                       : loom_txn_remove_output(txn.get(), id.bytes, port_name.c_str());
        if (removed != LOOM_OK || !txn.commit()) {
            fprintf(stderr, "loom: drop commit failed\n");
            return COMMAND_ERROR;
        }
        return COMMAND_OK;
    }

private:
    // True when any Input Port in the Fabric is bound to this output.
    static bool output_connected(const loom_store *store, const Id &id,
                                 const String &output_name) {
        const Size count = loom_store_count(store);
        for (Size i = 0; i < count; ++i) {
            Id other;
            if (loom_store_id_at(store, i, other.bytes) != LOOM_OK) {
                continue;
            }
            Size inputs = 0;
            loom_texel_input_count(store, other.bytes, &inputs);
            for (Size at = 0; at < inputs; ++at) {
                InputInfo info;
                if (loom_texel_input_at(store, other.bytes, at, &info.raw) != LOOM_OK) {
                    continue;
                }
                if (info.raw.bound && info.source().equals(id) &&
                    info.source_output() == output_name) {
                    return true;
                }
            }
        }
        return false;
    }
};

} // namespace lucia
