#include "commands/exit_command.h"

namespace lucia {

const char *ExitCommand::name() const {
    return "exit";
}

Size ExitCommand::argument_count() const {
    return 0;
}

const char *ExitCommand::usage() const {
    return "exit           leave the terminal";
}

CommandResult ExitCommand::run(Store *, const Strings &) {
    return COMMAND_EXIT;
}

} // namespace lucia
