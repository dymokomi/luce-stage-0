#pragma once

#include "command.h"
#include "commands/connect.h"
#include "commands/delete.h"
#include "commands/disconnect.h"
#include "commands/drop.h"
#include "commands/eval.h"
#include "commands/exit.h"
#include "commands/find.h"
#include "commands/help.h"
#include "commands/input.h"
#include "commands/list.h"
#include "commands/move.h"
#include "commands/new.h"
#include "commands/output.h"
#include "commands/pull.h"
#include "commands/rename.h"
#include "commands/select.h"
#include "commands/set.h"
#include "commands/show.h"

namespace lucia {

// ---------------------------------------------------------------------------
// CommandSet
// ---------------------------------------------------------------------------
//
// Every command available inside the loom terminal, owned as one set.
// Dispatch matches the first word against each command's name or alias,
// checks the argument count against the command's declared count, and
// prints its usage on a mismatch.
//
class CommandSet {
public:
    enum { COMMAND_COUNT = 18 };

    CommandSet();

    CommandResult run(Session *session, const Strings &words);

    Size           size() const;
    const Command *at(Size index) const;

private:
    CommandSet(const CommandSet &);
    CommandSet &operator=(const CommandSet &);

    NewCommand        new_command;
    SelectCommand     select_command;
    ShowCommand       show_command;
    RenameCommand     rename_command;
    FindCommand       find_command;
    DeleteCommand     delete_command;
    InputCommand      input_command;
    OutputCommand     output_command;
    MoveCommand       move_command;
    DropCommand       drop_command;
    ConnectCommand    connect_command;
    DisconnectCommand disconnect_command;
    SetCommand        set_command;
    EvalCommand       eval_command;
    PullCommand       pull_command;
    ListCommand       list_command;
    HelpCommand       help_command;
    ExitCommand       exit_command;

    Command *commands[COMMAND_COUNT];
};

} // namespace lucia
