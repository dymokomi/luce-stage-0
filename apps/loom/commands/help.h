#pragma once

#include <stdio.h>

#include "command.h"

namespace lucia {

// ---------------------------------------------------------------------------
// HelpCommand
// ---------------------------------------------------------------------------
//
// help — print the usage line of every command in the given list.  Borrows
// the list; the owner must outlive this command.
//
class HelpCommand : public Command {
public:
    HelpCommand(const Command *const *command_list, Size command_count)
        : commands(command_list), count(command_count) {}

    const char *name() const override {
        return "help";
    }

    Size argument_count() const override {
        return 0;
    }

    const char *alias() const override {
        return "?";
    }

    const char *usage() const override {
        return "help                     (?)   show this list";
    }

    CommandResult run(Session *, const Strings &) override {
        printf("commands:\n");
        for (Size i = 0; i < count; ++i) {
            printf("  %s\n", commands[i]->usage());
        }
        printf("\nTYPE: bool int real text bytes texel blob    DIR: in out\n");
        return COMMAND_OK;
    }

private:
    const Command *const *commands;
    Size                  count;
};

} // namespace lucia
