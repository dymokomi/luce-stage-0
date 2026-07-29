#pragma once

#include "base/types.h"
#include "session.h"

namespace lucia {

enum CommandResult {
    COMMAND_OK      = 0,
    COMMAND_ERROR   = 1,
    COMMAND_EXIT    = 2,
    COMMAND_UNKNOWN = 3
};

// ---------------------------------------------------------------------------
// Command
// ---------------------------------------------------------------------------
//
// One terminal command.  words[0] is the command name; the rest are its
// arguments, already checked against argument_count by the dispatcher.
// Commands return COMMAND_UNKNOWN never; that outcome belongs to dispatch.
//
class Command {
public:
    virtual ~Command() {}

    virtual const char *name() const           = 0;
    virtual Size        argument_count() const = 0;
    virtual const char *usage() const          = 0;

    // Optional short alias ("ls" for list); 0 when the command has none.
    virtual const char *alias() const {
        return 0;
    }

    virtual CommandResult run(Session *session, const Strings &words) = 0;
};

} // namespace lucia
