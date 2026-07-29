#include "command_set.h"

#include <stdio.h>

namespace lucia {

CommandSet::CommandSet() : help_command(commands, COMMAND_COUNT) {
    commands[0] = &new_command;
    commands[1] = &rename_command;
    commands[2] = &find_command;
    commands[3] = &delete_command;
    commands[4] = &list_command;
    commands[5] = &help_command;
    commands[6] = &exit_command;
}

CommandResult CommandSet::run(Store *store, const Strings &words) {
    for (Size i = 0; i < COMMAND_COUNT; ++i) {
        Command   *command = commands[i];
        const bool matched = words[0] == command->name() ||
                             (command->alias() != 0 && words[0] == command->alias());
        if (!matched) {
            continue;
        }
        if (words.size() - 1 != command->argument_count()) {
            fprintf(stderr, "usage: %s\n", command->usage());
            return COMMAND_ERROR;
        }
        return command->run(store, words);
    }
    return COMMAND_UNKNOWN;
}

Size CommandSet::size() const {
    return COMMAND_COUNT;
}

const Command *CommandSet::at(Size index) const {
    return index < COMMAND_COUNT ? commands[index] : 0;
}

} // namespace lucia
