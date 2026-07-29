#pragma once

#include "base/types.h"
#include "fabric/persistence/store.h"

namespace lucia {

// ---------------------------------------------------------------------------
// Terminal commands
// ---------------------------------------------------------------------------
//
// One entry point for every command typed inside the loom terminal.  The
// first word names the command; the rest are its arguments.
//
enum CommandResult {
  COMMAND_OK      = 0,
  COMMAND_ERROR   = 1,
  COMMAND_EXIT    = 2,
  COMMAND_UNKNOWN = 3
};

CommandResult run_command(Store *store, const Strings &words);

void print_commands();

} // namespace lucia
