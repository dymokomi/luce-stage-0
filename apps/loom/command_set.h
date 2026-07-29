#pragma once

#include "command.h"
#include "commands/delete.h"
#include "commands/exit.h"
#include "commands/find.h"
#include "commands/help.h"
#include "commands/list.h"
#include "commands/new.h"
#include "commands/rename.h"

namespace lucia {

// ---------------------------------------------------------------------------
// CommandSet
// ---------------------------------------------------------------------------
//
// Every command available inside the loom terminal, owned as one set.
// Dispatch matches the first word, checks the argument count against the
// command's declared count, and prints its usage on a mismatch.
//
class CommandSet {
public:
    enum { COMMAND_COUNT = 7 };

    CommandSet();

    CommandResult run(Store *store, const Strings &words);

    Size           size() const;
    const Command *at(Size index) const;

private:
    CommandSet(const CommandSet &);
    CommandSet &operator=(const CommandSet &);

    NewCommand    new_command;
    RenameCommand rename_command;
    FindCommand   find_command;
    DeleteCommand delete_command;
    ListCommand   list_command;
    HelpCommand   help_command;
    ExitCommand   exit_command;

    Command *commands[COMMAND_COUNT];
};

} // namespace lucia
