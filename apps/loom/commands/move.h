#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// MoveCommand
// ---------------------------------------------------------------------------
//
// move DIR OLD NEW — rename a port on the selected texel.  Renaming an
// Output Port rewires every Fiber bound to it in the same commit, so
// existing connections survive the new name.
//
class MoveCommand : public Command {
public:
    const char *name() const override {
        return "move";
    }

    Size argument_count() const override {
        return 3;
    }

    const char *alias() const override {
        return "mv";
    }

    const char *usage() const override {
        return "move DIR OLD NEW         (mv)  rename a port on the selected texel";
    }

    CommandResult run(Session *session, const Strings &words) override {
        bool is_input;
        if (!parse_direction(words[1], &is_input)) {
            return COMMAND_ERROR;
        }
        if (!selected_exists(*session)) {
            return COMMAND_ERROR;
        }
        const String &old_name = words[2];
        const String &new_name = words[3];
        return is_input ? move_input(session, old_name, new_name)
                        : move_output(session, old_name, new_name);
    }

private:
    static CommandResult move_input(Session *session, const String &old_name,
                                    const String &new_name) {
        const Id &id = session->selected;
        InputInfo port;
        if (!find_input(session->store, id, old_name, &port)) {
            fprintf(stderr, "loom: no input named %s\n", old_name.c_str());
            return COMMAND_ERROR;
        }
        InputInfo duplicate;
        if (find_input(session->store, id, new_name, &duplicate)) {
            fprintf(stderr, "loom: input %s already exists\n", new_name.c_str());
            return COMMAND_ERROR;
        }

        Txn txn(session->store);
        if (!txn.ok() ||
            loom_txn_remove_input(txn.get(), id.bytes, old_name.c_str()) != LOOM_OK ||
            loom_txn_put_input(txn.get(), id.bytes, new_name.c_str(), port.raw.type) !=
                LOOM_OK) {
            fprintf(stderr, "loom: move commit failed\n");
            return COMMAND_ERROR;
        }
        if (port.raw.bound &&
            loom_txn_connect(txn.get(), id.bytes, new_name.c_str(), port.raw.source,
                             port.source_output().c_str()) != LOOM_OK) {
            fprintf(stderr, "loom: move commit failed\n");
            return COMMAND_ERROR;
        }
        if (!txn.commit()) {
            fprintf(stderr, "loom: move commit failed\n");
            return COMMAND_ERROR;
        }
        return COMMAND_OK;
    }

    static CommandResult move_output(Session *session, const String &old_name,
                                     const String &new_name) {
        const Id  &id = session->selected;
        OutputInfo port;
        if (!find_output(session->store, id, old_name, &port)) {
            fprintf(stderr, "loom: no output named %s\n", old_name.c_str());
            return COMMAND_ERROR;
        }
        OutputInfo duplicate;
        if (find_output(session->store, id, new_name, &duplicate)) {
            fprintf(stderr, "loom: output %s already exists\n", new_name.c_str());
            return COMMAND_ERROR;
        }

        Txn txn(session->store);
        if (!txn.ok() ||
            loom_txn_remove_output(txn.get(), id.bytes, old_name.c_str()) != LOOM_OK ||
            loom_txn_put_output(txn.get(), id.bytes, new_name.c_str(), port.raw.type) !=
                LOOM_OK) {
            fprintf(stderr, "loom: move commit failed\n");
            return COMMAND_ERROR;
        }
        if (port.raw.has_source) {
            // The border borrows the value; re-point text and bytes at
            // the inspected copy for the duration of the call.
            loom_value carried = port.raw.source;
            if (loom_txn_set_source(txn.get(), id.bytes, new_name.c_str(), &carried) !=
                LOOM_OK) {
                fprintf(stderr, "loom: move commit failed\n");
                return COMMAND_ERROR;
            }
        }

        // Repoint every Fiber bound to the old output name, in the same
        // atomic commit.
        const Size count = loom_store_count(session->store);
        for (Size i = 0; i < count; ++i) {
            Id other;
            if (loom_store_id_at(session->store, i, other.bytes) != LOOM_OK) {
                return COMMAND_ERROR;
            }
            if (other.equals(id)) {
                continue;
            }
            Size inputs = 0;
            loom_texel_input_count(session->store, other.bytes, &inputs);
            for (Size at = 0; at < inputs; ++at) {
                InputInfo bound;
                if (loom_texel_input_at(session->store, other.bytes, at, &bound.raw) !=
                    LOOM_OK) {
                    return COMMAND_ERROR;
                }
                if (!bound.raw.bound || !bound.source().equals(id) ||
                    bound.source_output() != old_name) {
                    continue;
                }
                if (loom_txn_connect(txn.get(), other.bytes, bound.name().c_str(), id.bytes,
                                     new_name.c_str()) != LOOM_OK) {
                    fprintf(stderr, "loom: move commit failed\n");
                    return COMMAND_ERROR;
                }
            }
        }
        if (!txn.commit()) {
            fprintf(stderr, "loom: move commit failed\n");
            return COMMAND_ERROR;
        }
        return COMMAND_OK;
    }
};

} // namespace lucia
