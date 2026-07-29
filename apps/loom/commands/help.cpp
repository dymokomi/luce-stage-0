#include "commands/help.h"

#include <stdio.h>

#include "command_set.h"

namespace lucia {

HelpCommand::HelpCommand(const CommandSet *command_set) : commands(command_set) {}

const char *HelpCommand::name() const {
    return "help";
}

Size HelpCommand::argument_count() const {
    return 0;
}

const char *HelpCommand::usage() const {
    return "help           show this list";
}

CommandResult HelpCommand::run(Store *, const Strings &) {
    printf("commands:\n");
    for (Size i = 0; i < commands->size(); ++i) {
        printf("  %s\n", commands->at(i)->usage());
    }
    return COMMAND_OK;
}

} // namespace lucia
