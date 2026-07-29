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
// Output Port rewrites every Fiber bound to it in the same commit, so
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
        Texel texel;
        if (!selected_texel(*session, &texel)) {
            return COMMAND_ERROR;
        }
        const String &old_name = words[2];
        const String &new_name = words[3];
        const bool    moved    = is_input ? move_input(&texel, old_name, new_name)
                                          : move_output(&texel, old_name, new_name);
        if (!moved) {
            return COMMAND_ERROR;
        }
        if (is_input ? !commit_put(session->store, texel)
                     : !commit_with_rebinds(session->store, texel, old_name, new_name)) {
            fprintf(stderr, "loom: move commit failed\n");
            return COMMAND_ERROR;
        }
        return COMMAND_OK;
    }

private:
    static bool move_input(Texel *texel, const String &old_name, const String &new_name) {
        InputPort port;
        if (!texel->get_input(old_name.c_str(), &port)) {
            fprintf(stderr, "loom: no input named %s\n", old_name.c_str());
            return false;
        }
        if (texel->has_input(new_name.c_str())) {
            fprintf(stderr, "loom: input %s already exists\n", new_name.c_str());
            return false;
        }
        InputPort renamed(new_name.c_str(), port.type());
        if (port.has_binding()) {
            renamed.bind(port.binding());
        }
        texel->remove_input(old_name.c_str());
        texel->put_input(renamed);
        return true;
    }

    static bool move_output(Texel *texel, const String &old_name, const String &new_name) {
        OutputPort port;
        if (!texel->get_output(old_name.c_str(), &port)) {
            fprintf(stderr, "loom: no output named %s\n", old_name.c_str());
            return false;
        }
        if (texel->has_output(new_name.c_str())) {
            fprintf(stderr, "loom: output %s already exists\n", new_name.c_str());
            return false;
        }
        OutputPort renamed(new_name.c_str(), port.type());
        if (port.has_source()) {
            renamed.set_source(port.source());
        }
        renamed.set_revision(port.revision());
        texel->remove_output(old_name.c_str());
        texel->put_output(renamed);
        return true;
    }

    // Commit the renamed texel and repoint every Fiber that referenced the
    // old output name, all in one atomic transaction.
    static bool commit_with_rebinds(Store *store, const Texel &texel,
                                    const String &old_name, const String &new_name) {
        Transaction transaction;
        if (!store->begin(&transaction) || !transaction.put(texel)) {
            return false;
        }
        for (Size i = 0; i < store->size(); ++i) {
            Texel other;
            if (!store->at(i, &other)) {
                return false;
            }
            if (other.id().equals(texel.id())) {
                continue;
            }
            bool changed = false;
            for (Size j = 0; j < other.input_size(); ++j) {
                InputPort input;
                other.input_at(j, &input);
                if (!input.has_binding() || !input.binding().source().equals(texel.id()) ||
                    input.binding().output() != old_name) {
                    continue;
                }
                input.bind(Fiber(texel.id(), new_name.c_str()));
                other.put_input(input);
                changed = true;
            }
            if (changed && !transaction.put(other)) {
                return false;
            }
        }
        return transaction.commit();
    }
};

} // namespace lucia
