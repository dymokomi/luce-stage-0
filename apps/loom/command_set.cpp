#include "command_set.h"

#include <stdio.h>

namespace lucia {

CommandSet::CommandSet() : help_command(commands, COMMAND_COUNT) {
    commands[0]  = &new_command;
    commands[1]  = &select_command;
    commands[2]  = &show_command;
    commands[3]  = &rename_command;
    commands[4]  = &find_command;
    commands[5]  = &delete_command;
    commands[6]  = &input_command;
    commands[7]  = &output_command;
    commands[8]  = &move_command;
    commands[9]  = &drop_command;
    commands[10] = &connect_command;
    commands[11] = &disconnect_command;
    commands[12] = &set_command;
    commands[13] = &eval_command;
    commands[14] = &pull_command;
    commands[15] = &watch_command;
    commands[16] = &unwatch_command;
    commands[17] = &list_command;
    commands[18] = &help_command;
    commands[19] = &exit_command;
}

CommandResult CommandSet::run(Session *session, const Strings &words) {
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
        return command->run(session, words);
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
